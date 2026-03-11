// Initialize app users for shoppingo and jewellery-catalogue
// Run via: docker exec -it mongodb mongosh /docker-entrypoint-initdb.d/01-create-users.js

// Get password from docker-compose .env or environment
const appPassword = process.env.APP_PASSWORD || 'changeme';

// Create shoppingo databases and user
db = db.getSiblingDB('shoppingo_production');
db.createUser({
  user: 'shoppingo_production_user',
  pwd: appPassword,
  roles: ['readWrite']
});

db = db.getSiblingDB('shoppingo_staging');
db.createUser({
  user: 'shoppingo_staging_user',
  pwd: appPassword,
  roles: ['readWrite']
});

// Create jewellery-catalogue databases and user
db = db.getSiblingDB('jewellery_production');
db.createUser({
  user: 'jewellery_production_user',
  pwd: appPassword,
  roles: ['readWrite']
});

db = db.getSiblingDB('jewellery_staging');
db.createUser({
  user: 'jewellery_staging_user',
  pwd: appPassword,
  roles: ['readWrite']
});
