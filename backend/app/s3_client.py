import os
from dotenv import load_dotenv
import boto3

load_dotenv() # Загружает переменные из .env

s3 = boto3.client(
    "s3",
    endpoint_url=os.getenv("S3_ENDPOINT"),
    aws_access_key_id=os.getenv("S3_ACCESS_KEY"),
    aws_secret_access_key=os.getenv("S3_SECRET_KEY"),
    region_name="ru-central1"
)
BUCKET_NAME = os.getenv("S3_BUCKET")