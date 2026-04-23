import { parse } from 'yaml';
import { readFileSync } from 'fs';
import { join } from 'path';

function ensureArray<T>(value: unknown): T[] {
  if (!Array.isArray(value)) {
    throw new Error(`Expected array, got ${typeof value}`);
  }
  return value as T[];
}

const UPTIME_KUMA_URL = process.env.UPTIME_KUMA_URL || 'http://localhost:3001';
const UPTIME_KUMA_API_KEY = process.env.UPTIME_KUMA_API_KEY;

interface MonitorConfig {
  name: string;
  type: 'http' | 'tcp';
  url?: string;
  host?: string;
  port?: number;
  interval: number;
  maxretries: number;
}

interface Config {
  monitors: Record<string, MonitorConfig>;
  dashboard: {
    name: string;
    description: string;
  };
}

interface MonitorPayload {
  name: string;
  type: 'http' | 'tcp';
  interval: number;
  maxretries: number;
  active: number;
  url?: string;
  method?: string;
  expectedValue?: string;
  invertKeyword?: number;
  hostname?: string;
  port?: number;
}

async function apiCall(
  method: string,
  endpoint: string,
  body?: unknown
): Promise<unknown> {
  const url = `${UPTIME_KUMA_URL}/api${endpoint}`;
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };

  if (UPTIME_KUMA_API_KEY) {
    headers['X-API-Key'] = UPTIME_KUMA_API_KEY;
  }

  const response = await fetch(url, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });

  if (!response.ok) {
    const text = await response.text();
    const error = new Error(`API Error: ${response.status} ${text}`);
    (error as any).status = response.status;
    throw error;
  }

  const contentType = response.headers.get('content-type');
  if (contentType?.includes('application/json')) {
    return await response.json();
  }
  return null;
}

function loadConfig(): Config {
  const configPath = join(import.meta.dir, '..', 'uptime-kuma-config.yml');
  const fileContent = readFileSync(configPath, 'utf8');
  return parse(fileContent) as Config;
}

async function testConnection(): Promise<boolean> {
  try {
    await apiCall('GET', '/heartbeat');
    console.log('✓ Connected to uptime-kuma');
    return true;
  } catch (error) {
    console.error(
      '✗ Failed to connect to uptime-kuma:',
      error instanceof Error ? error.message : String(error)
    );
    return false;
  }
}

function buildMonitorPayload(config: MonitorConfig): MonitorPayload {
  const payload: MonitorPayload = {
    name: config.name,
    type: config.type,
    interval: config.interval,
    maxretries: config.maxretries,
    active: 1,
  };

  if (config.type === 'http') {
    payload.url = config.url;
    payload.method = 'GET';
    payload.expectedValue = '';
    payload.invertKeyword = 0;
  } else if (config.type === 'tcp') {
    payload.hostname = config.host;
    payload.port = config.port;
  }

  return payload;
}

async function createOrUpdateMonitor(
  monitorConfig: MonitorConfig
): Promise<number> {
  try {
    // Check if monitor already exists
    const listResponse = ensureArray<{ id: number; name: string }>(
      await apiCall('GET', '/monitor')
    );
    const existingMonitor = listResponse.find(
      (m) => m.name === monitorConfig.name
    );

    const payload = buildMonitorPayload(monitorConfig);

    if (existingMonitor) {
      // Update existing
      await apiCall('PATCH', `/monitor/${existingMonitor.id}`, payload);
      console.log(`  ↻ Updated: ${monitorConfig.name}`);
      return existingMonitor.id;
    } else {
      // Create new
      const response = (await apiCall('POST', '/monitor', payload)) as {
        monitorID: number;
      };
      console.log(`  + Created: ${monitorConfig.name}`);
      return response.monitorID;
    }
  } catch (error) {
    console.error(
      `  ✗ Error with ${monitorConfig.name}:`,
      error instanceof Error ? error.message : String(error)
    );
    throw error;
  }
}

async function createDashboard(monitors: number[], config: Config): Promise<number> {
  try {
    // Check if dashboard exists
    const listResponse = ensureArray<{ id: number; title: string }>(
      await apiCall('GET', '/status-page')
    );
    const existingDashboard = listResponse.find(
      (d) => d.title === config.dashboard.name
    );

    const dashboardPayload = {
      title: config.dashboard.name,
      description: config.dashboard.description,
      slug: config.dashboard.name.toLowerCase().replace(/\s+/g, '-'),
      showTags: 1,
      published: 1,
    };

    let dashboardId: number;

    if (existingDashboard) {
      await apiCall(
        'PATCH',
        `/status-page/${existingDashboard.id}`,
        dashboardPayload
      );
      dashboardId = existingDashboard.id;
      console.log(`  ↻ Updated dashboard: ${config.dashboard.name}`);
    } else {
      const response = (await apiCall(
        'POST',
        '/status-page',
        dashboardPayload
      )) as { id: number };
      dashboardId = response.id;
      console.log(`  + Created dashboard: ${config.dashboard.name}`);
    }

    // Add monitors to dashboard
    for (const monitorId of monitors) {
      try {
        await apiCall('POST', `/status-page/${dashboardId}/monitor/${monitorId}`, {});
      } catch (error) {
        // Monitor may already be on dashboard
        if (!(error instanceof Error) || (error as any).status !== 409) {
          throw error;
        }
      }
    }

    console.log(`  ✓ Added ${monitors.length} monitors to dashboard`);
    return dashboardId;
  } catch (error) {
    console.error(
      '✗ Error creating/updating dashboard:',
      error instanceof Error ? error.message : String(error)
    );
    throw error;
  }
}

async function main(): Promise<void> {
  console.log('Uptime-Kuma Setup\n');

  if (!UPTIME_KUMA_API_KEY) {
    console.warn(
      '⚠ UPTIME_KUMA_API_KEY not set. Create .env from .env.example'
    );
  }

  try {
    // Test connection
    const connected = await testConnection();
    if (!connected) process.exit(1);

    // Load config
    console.log('\n📋 Loading configuration...');
    const config = loadConfig();

    // Create monitors
    console.log('\n🔍 Setting up monitors...');
    const monitorIds: number[] = [];
    for (const [, monitorConfig] of Object.entries(config.monitors)) {
      const id = await createOrUpdateMonitor(monitorConfig);
      monitorIds.push(id);
    }

    // Validate monitors were created
    if (monitorIds.length === 0) {
      console.warn('⚠ No monitors were created');
    }

    // Create dashboard
    console.log('\n📊 Setting up dashboard...');
    const dashboardSlug = config.dashboard.name.toLowerCase().replace(/\s+/g, '-');
    await createDashboard(monitorIds, config);

    console.log('\n✓ Setup complete!');
    console.log(
      `View dashboard at: ${UPTIME_KUMA_URL}/status/${dashboardSlug}`
    );
  } catch (error) {
    console.error(
      '\n✗ Setup failed:',
      error instanceof Error ? error.message : String(error)
    );
    process.exit(1);
  }
}

main();
