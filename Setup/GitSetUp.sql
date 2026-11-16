-- Copyright © 2026 Innovation In Software Corporation. All rights reserved.
-- SnowPro Advanced: Architect — connect Snowsight Workspaces to the class repository
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE API INTEGRATION GIT_GITHUB_INT
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/innovationinsoftware')
  ENABLED = TRUE;


-- When creating a Workspace from Git repository use the following:
-- Repository URL: https://github.com/innovationinsoftware/snowflake-ara
-- Workspace Name: snowpro-advanced-architect
-- API Integration: GIT_GITHUB_INT
-- Public repository
