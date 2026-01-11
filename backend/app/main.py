from fastapi import FastAPI, Depends, UploadFile, File, HTTPException
from sqlalchemy.orm import Session
import models, database, s3_client
import uuid
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="CloudMedia Hub API")

# Настройка CORS, чтобы React мог достучаться до API
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], # В реальном проекте здесь будет URL твоего фронтенда
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app = FastAPI(title="CloudMedia Hub API")
models.Base.metadata.create_all(bind=database.engine)

# CRUD: CREATE (Загрузка файла)
@app.post("/upload/")
async def upload_file(file: UploadFile = File(...), db: Session = Depends(database.get_db)):
    # Генерируем уникальное имя для S3
    file_ext = file.filename.split(".")[-1]
    unique_filename = f"{uuid.uuid4()}.{file_ext}"
    
    try:
        # 1. Загружаем в Yandex Object Storage
        s3_client.s3.upload_fileobj(file.file, s3_client.BUCKET_NAME, unique_filename)
        
        # 2. Записываем метаданные в PostgreSQL
        db_file = models.MediaFile(
            filename=file.filename,
            s3_key=unique_filename,
            file_type=file_ext
        )
        db.add(db_file)
        db.commit()
        db.refresh(db_file)
        
        return {"id": db_file.id, "status": "Uploaded", "s3_key": unique_filename}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# CRUD: READ (Список файлов)
@app.get("/files/")
def list_files(db: Session = Depends(database.get_db)):
    return db.query(models.MediaFile).all()

# CRUD: DELETE
@app.delete("/files/{file_id}")
def delete_file(file_id: int, db: Session = Depends(database.get_db)):
    file_record = db.query(models.MediaFile).filter(models.MediaFile.id == file_id).first()
    if not file_record:
        raise HTTPException(status_code=404, detail="File not found")
    
    # Удаляем из S3 и из БД
    s3_client.s3.delete_object(Bucket=s3_client.BUCKET_NAME, Key=file_record.s3_key)
    db.delete(file_record)
    db.commit()
    return {"message": "Deleted successfully"}

@app.get("/")
def read_root():
    return {"message": "CloudMedia Hub API is running!", "docs": "/docs"}