// Initialize app users for shoppingo and jewellery-catalogue
// Auto-runs on container start if not already initialized

// Create shoppingo databases and user
db = db.getSiblingDB('shoppingo_production');
db.createUser({
  user: 'shoppingo_production_user',
  pwd: 'changeme',
  roles: ['readWrite']
});

db = db.getSiblingDB('shoppingo_staging');
db.createUser({
  user: 'shoppingo_staging_user',
  pwd: 'changeme',
  roles: ['readWrite']
});

// Create jewellery-catalogue databases and user
db = db.getSiblingDB('jewellery_production');
db.createUser({
  user: 'jewellery_production_user',
  pwd: 'changeme',
  roles: ['readWrite']
});

db = db.getSiblingDB('jewellery_staging');
db.createUser({
  user: 'jewellery_staging_user',
  pwd: 'changeme',
  roles: ['readWrite']
});
