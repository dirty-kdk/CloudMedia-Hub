import React, { useState, useEffect } from 'react';
import axios from 'axios';
import './App.css';

const API_URL = "http://158.160.191.58"; 
const BUCKET_URL = "https://storage.yandexcloud.net/krokhalev-unique-media-bucket-2026"; 

function App() {
  const [files, setFiles] = useState([]);
  const [loading, setLoading] = useState(false);

  const loadData = () => {
    axios.get(`${API_URL}/files/`).then(res => setFiles(res.data));
  };

  useEffect(() => { loadData(); }, []);

  const onUpload = async (e) => {
    setLoading(true);
    const fd = new FormData();
    fd.append("file", e.target.files[0]);
    await axios.post(`${API_URL}/upload/`, fd);
    setLoading(false);
    loadData();
  };

  const onDelete = async (id) => {
    await axios.delete(`${API_URL}/files/${id}`);
    loadData();
  };

  return (
    <div className="container">
      <div className="header">
        <h1>☁️ CloudMedia Hub</h1>
        <p>Ваше личное облачное хранилище с авто-превью</p>
      </div>

      <div className="upload-card">
        <label className="btn-upload">
          {loading ? "Загрузка..." : "Загрузить новое фото"}
          <input type="file" hidden onChange={onUpload} disabled={loading} />
        </label>
      </div>

      <div className="grid">
        {files.map(f => (
          <div className="card" key={f.id}>
            {/* Сначала пытаемся показать превью, если не вышло - оригинал */}
            <img 
              src={`${BUCKET_URL}/thumbnails/${f.s3_key}`} 
              onError={(e) => {e.target.src = `${BUCKET_URL}/${f.s3_key}`}}
              alt="media" 
            />
            <div className="card-info">
              <span>{f.filename.truncate(15)}</span>
              <button className="btn-delete" onClick={() => onDelete(f.id)}>🗑️</button>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

String.prototype.truncate = function(n) { return (this.length > n) ? this.substr(0, n-1) + '...' : this; };

export default App;

