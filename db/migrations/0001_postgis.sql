-- PostGIS must be allow-listed on the server first (azure.extensions = POSTGIS, set by Terraform).
CREATE EXTENSION IF NOT EXISTS postgis;
