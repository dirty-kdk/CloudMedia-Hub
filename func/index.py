import boto3
import os
from PIL import Image
from io import BytesIO

# Настройки S3 (берем из переменных окружения, которые настроим в Terraform)
s3 = boto3.client(
    "s3",
    endpoint_url="https://storage.yandexcloud.net",
    aws_access_key_id=os.environ['ACCESS_KEY'],
    aws_secret_access_key=os.environ['SECRET_KEY']
)

def handler(event, context):
    # Достаем имя бакета и файла из события (триггера)
    bucket_id = event['messages'][0]['details']['bucket_id']
    object_id = event['messages'][0]['details']['object_id']

    # Если файл уже в папке thumbnails, игнорируем его (чтобы не зациклиться)
    if object_id.startswith('thumbnails/'):
        return

    # 1. Скачиваем картинку из S3 в память
    get_obj = s3.get_object(Bucket=bucket_id, Key=object_id)
    img = Image.open(BytesIO(get_obj['Body'].read()))

    # 2. Уменьшаем картинку (делаем превью 200x200)
    img.thumbnail((200, 200))
    
    # Сохраняем результат в буфер
    buffer = BytesIO()
    img.save(buffer, format=img.format)
    buffer.seek(0)

    # 3. Загружаем превью обратно в бакет в папку thumbnails/
    new_key = f"thumbnails/{object_id}"
    s3.put_object(Bucket=bucket_id, Key=new_key, Body=buffer)

    print(f"Превью для {object_id} успешно создано!")