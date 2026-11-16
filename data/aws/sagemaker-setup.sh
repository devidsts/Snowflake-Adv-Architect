#!/usr/bin/env bash
# SnowPro Advanced: Architect — SageMaker Studio (JupyterLab) setup for Hands-on #06c
# Copyright © 2026 Innovation In Software Corporation. All rights reserved.
# Run in a JupyterLab terminal (File › New › Terminal) from the root of the lab folder:
#     bash data/aws/sagemaker-setup.sh
set -euo pipefail
echo "== Snowpark for the notebook kernel"
pip install --quiet --upgrade "snowflake-snowpark-python[pandas]" cryptography
python -c "import snowflake.snowpark as s; print('   snowflake-snowpark-python', s.__version__)"

echo "== Key pair for the SMITH_SNOWPARK_SVC service user"
mkdir -p ~/.snowflake && chmod 700 ~/.snowflake
if [ ! -f ~/.snowflake/rsa_key.p8 ]; then
  openssl genrsa 2048 2>/dev/null | openssl pkcs8 -topk8 -inform PEM -out ~/.snowflake/rsa_key.p8 -nocrypt
  openssl rsa -in ~/.snowflake/rsa_key.p8 -pubout -out ~/.snowflake/rsa_key.pub 2>/dev/null
  chmod 600 ~/.snowflake/rsa_key.p8
fi
echo "   Paste this into Hands-on #06c, Demo 1 (ALTER USER ... SET RSA_PUBLIC_KEY):"
grep -v "PUBLIC KEY" ~/.snowflake/rsa_key.pub | tr -d '\n'; echo
echo "== Done. Open notebooks/06c-Snowpark-Python.ipynb with the Python 3 (ipykernel) kernel."
