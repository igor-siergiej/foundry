# OpenSearch

Single-node OpenSearch 2.x backing shoppingo's recipe discovery search. It is a **derived** index: MongoDB is the system
of record, and shoppingo rebuilds this with `bun run reindex:discovery` if the volume is lost, so the volume is not
backed up.

- Internal network only (no published port, no Traefik route). The security plugin is disabled, so anything on
  `dokploy-network` can read and write it; do not expose it.
- `-Xms1g -Xmx1g` heap, 2 GB container limit (`mem_limit`). Host needs `vm.max_map_count >= 262144` (it is 1048576).
- shoppingo API setting: `OPENSEARCH_URL=http://opensearch:9200`.
- Search design: see `docs/discovery-search.md` in the shoppingo repo.

Deploy as a Dokploy compose app (`compose-deploy` explicitly after pushing; the webhook is unreliable).
