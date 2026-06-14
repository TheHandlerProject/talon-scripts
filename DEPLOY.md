# PPP App — Deploy to Zion

## Stack
- React (Vite) frontend
- Node/Express backend
- PostgreSQL database
- Nginx reverse proxy
- Cloudflare tunnel → public URL

---

## 1. Project Setup on Zion

```bash
ssh rocinante  # or however you get to Zion

mkdir -p ~/ppp-app/{frontend,backend}
cd ~/ppp-app
```

---

## 2. Frontend (React/Vite)

```bash
cd ~/ppp-app/frontend
npm create vite@latest . -- --template react
npm install
```

Drop `ppp-app.jsx` into `src/App.jsx`  
Drop `index.html` into project root  
Drop `manifest.json` into `public/`  
Drop `sw.js` into `public/`  
Drop `icons/` folder into `public/icons/`  

```bash
# src/main.jsx
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App.jsx'
ReactDOM.createRoot(document.getElementById('root')).render(<App />)
```

Build for production:
```bash
npm run build
# Output goes to dist/
```

---

## 3. Backend (Node/Express)

```bash
cd ~/ppp-app/backend
npm init -y
npm install express pg dotenv cors jsonwebtoken bcryptjs passport passport-google-oauth20
```

Create `.env`:
```
PORT=3001
DB_USER=postgres
DB_PASSWORD=yourpassword
DB_HOST=localhost
DB_PORT=5432
DB_NAME=ppp_app
JWT_SECRET=yourjwtsecret
GOOGLE_CLIENT_ID=from_google_console
GOOGLE_CLIENT_SECRET=from_google_console
SESSION_SECRET=yoursessionsecret
```

---

## 4. PostgreSQL

```bash
sudo -u postgres psql
CREATE DATABASE ppp_app;
CREATE USER ppp_user WITH PASSWORD 'yourpassword';
GRANT ALL PRIVILEGES ON DATABASE ppp_app TO ppp_user;
\q
```

---

## 5. Nginx Config

```nginx
# /etc/nginx/sites-available/ppp
server {
    listen 80;
    server_name ppp.sfer.me;

    # Serve React build
    location / {
        root /home/evan/ppp-app/frontend/dist;
        try_files $uri $uri/ /index.html;
    }

    # Proxy API to Node backend
    location /api/ {
        proxy_pass http://localhost:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/ppp /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

---

## 6. Cloudflare Tunnel

In Zero Trust dashboard → Networks → Tunnels → your tunnel → Public Hostnames:

| Subdomain | Domain  | Service               |
|-----------|---------|----------------------|
| ppp       | sfer.me | http://localhost:80  |

App will be live at: **https://ppp.sfer.me**

---

## 7. Run as systemd service

```bash
# /etc/systemd/system/ppp-backend.service
[Unit]
Description=PPP Backend
After=network.target

[Service]
User=evan
WorkingDirectory=/home/evan/ppp-app/backend
ExecStart=/usr/bin/node server.js
Restart=always
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable ppp-backend
sudo systemctl start ppp-backend
```

---

## 8. Client Install Instructions (for your website)

Add to thehandlerproject.com:

> **Download the PPP App**  
> Visit **ppp.sfer.me** on your phone  
> Tap Share → Add to Home Screen (iOS)  
> Tap Menu → Add to Home Screen (Android)

---

## Google OAuth Setup

1. Go to console.cloud.google.com
2. New project → APIs & Services → Credentials
3. Create OAuth 2.0 Client ID
4. Authorized redirect URI: `https://ppp.sfer.me/api/auth/google/callback`
5. Copy Client ID and Secret to `.env`

