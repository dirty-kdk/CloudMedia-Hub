from sqlalchemy import Column, Integer, String, DateTime
from datetime import datetime
from database import Base

# Это описание нашей таблицы в базе данных
class MediaFile(Base):
    __tablename__ = "media_files" # Имя таблицы в Postgres

    id = Column(Integer, primary_key=True, index=True)
    filename = Column(String)       # Имя файла
    s3_key = Column(String)         # Путь к файлу в Object Storage
    file_type = Column(String)      # Тип (jpg, png и т.д.)
    created_at = Column(DateTime, default=datetime.utcnow)