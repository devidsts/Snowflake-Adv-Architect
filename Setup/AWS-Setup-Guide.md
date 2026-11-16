# AWS Setup — Hands-on #06b, #06c and #06d

**Copyright © 2026 Innovation In Software Corporation. All rights reserved.**

Three labs use AWS: **#06b** (Snowpipe from S3), **#06c** (Snowpark with Python) and **#06d** (Iceberg tables on S3). Students work in two browser-based AWS tools, so nothing is installed on their computers:

| Tool | Used for | Why |
|---|---|---|
| **AWS CloudShell** | S3 bucket, file uploads, `aws s3` commands, optional IAM CLI | Built into the console; AWS CLI and git preinstalled; uses the student's own console permissions; 1 GB persistent home per region; no charge |
| **Amazon SageMaker Studio — JupyterLab** | The Snowpark notebook in #06c | Managed JupyterLab in the browser with a terminal; Python, pip and openssl included |

AWS Cloud9 is not used: AWS closed it to new customers on July 25, 2024, and these are new AWS accounts. (AWS's own replacements are CloudShell and the AWS IDE Toolkits for local IDEs; SageMaker Studio adds a hosted JupyterLab and a VS Code–based Code Editor.)

## Before class (instructor or AWS administrator)

1. Each student needs an AWS account (or IAM user) that can use S3, IAM, CloudShell and SageMaker AI.
2. Use the **same AWS region as the students' Snowflake trial accounts** — US East (N. Virginia) or US West (Oregon).
3. **SageMaker Studio domain** (once per account, ~5–10 minutes, so do it before class): SageMaker AI console › **Domains › Create domain › Set up for single user (Quick setup)**. Quick setup creates the execution role and gives Studio internet access, which the notebook needs to reach Snowflake.
4. Cost: CloudShell is free. A JupyterLab space on **ml.t3.medium** is in the SageMaker free tier (250 hours per month for the first 2 months of a new account); otherwise it costs a few cents per hour. Stop the space after class.

## Hands-on #06b — CloudShell

1. Open **CloudShell** (terminal icon in the console's top bar) in the right region.
2. Get the lab files into CloudShell: **Actions › Upload file** › upload the lab zip, then `unzip "Snowflake Adv Architect Labs.zip" && cd "Snowflake Adv Architect Labs"` (or `git clone` the class repository).
3. Run:

   ```text
   export BUCKET=smith-ins-landing-<your-initials>-<4 digits>
   bash data/aws/cloudshell-setup.sh
   ```

   This creates the bucket, uploads `data/s3_agency_claims/` (60 JSON + 2 CSV) to `s3://$BUCKET/agency_claims/`, and writes the IAM policies with your bucket name to `~/smith-aws/`.

4. **IAM role** (IAM console): **Policies › Create policy › JSON** › paste `~/smith-aws/s3-read-policy.json` (`cat` it in CloudShell) › name `smith-snowflake-s3-read`. **Roles › Create role › AWS account › This account**, tick **Require external ID** (enter `0000` for now), attach the policy, name it `smith-snowflake-s3-role`. Copy the role ARN into the lab.
5. After #06b Demo 1, edit the role's **Trust relationships** with `data/aws/snowflake-trust-policy.json` and the two values from `DESC STORAGE INTEGRATION`.
6. After #06b Demo 3, add the S3 event notification (console: bucket › Properties › Event notifications › prefix `agency_claims/`, All object create events, SQS queue ARN = `notification_channel`), or in CloudShell edit `data/aws/s3-event-notification.json` and run
   `aws s3api put-bucket-notification-configuration --bucket $BUCKET --notification-configuration file://data/aws/s3-event-notification.json`
7. #06b Demo 5: `aws s3 cp data/s3_agency_claims_late/ s3://$BUCKET/agency_claims/ --recursive`

## Hands-on #06c — SageMaker Studio JupyterLab

1. SageMaker AI console › **Studio** › Open Studio › **JupyterLab › Create JupyterLab space** (name `snowpark`, instance **ml.t3.medium**, default SageMaker Distribution image) › **Run space** › **Open JupyterLab**.
2. Upload the lab zip (upload button in the file browser), then in **File › New › Terminal**:

   ```text
   unzip "Snowflake Adv Architect Labs.zip" && cd "Snowflake Adv Architect Labs"
   bash data/aws/sagemaker-setup.sh
   ```

   This installs Snowpark into the notebook's Python and creates the RSA key pair in `~/.snowflake/`. Paste the printed public key into #06c Demo 1.
3. Open `notebooks/06c-Snowpark-Python.ipynb` with the **Python 3 (ipykernel)** kernel. If the import fails right after installing, use **Kernel › Restart Kernel**.

## Hands-on #06d — Iceberg (CloudShell + IAM)

1. IAM: create policy `smith-snowflake-iceberg-rw` from `~/smith-aws/iceberg-rw-policy.json` and role `smith-snowflake-iceberg-role` the same way as in #06b. Copy its ARN into #06d Demo 1.
2. After `DESC EXTERNAL VOLUME`, update that role's trust policy with the volume's IAM user ARN and external ID.
3. Look at the Iceberg files: `aws s3 ls s3://$BUCKET/iceberg/ --recursive`

## Cleanup (end of class)

- CloudShell: `aws s3 rm s3://$BUCKET --recursive && aws s3api delete-bucket --bucket $BUCKET`
- IAM: delete both roles and both policies.
- SageMaker: **stop** the JupyterLab space (and delete the domain if the account is temporary).
