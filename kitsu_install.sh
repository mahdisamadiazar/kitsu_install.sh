#!/bin/bash

#Dependencies-----------------------------------------------------------

#First let's install third parties software:
sudo apt-get install postgresql postgresql-client postgresql-server-dev-all
sudo apt-get install redis-server
sudo apt-get install python3 python3-pip
sudo apt-get install git
sudo apt-get install nginx
sudo apt-get install ffmpeg

#Get sources------------------------------------------------------------

#Create zou user:
sudo mkdir /opt/zou
sudo chown zou: /opt/zou
sudo mkdir /opt/zou/backups
sudo chown zou: /opt/zou/backups

#Install Zou and its dependencies:
sudo pip3 install virtualenv
cd /opt/zou
sudo virtualenv zouenv
sudo /opt/zou/zouenv/bin/pip3 install zou
sudo chown -R zou:www-data .

#Create a folder to store the previews:
sudo mkdir /opt/zou/previews
sudo chown -R zou:www-data /opt/zou

#Create a folder to store the temp files:
sudo mkdir /opt/zou/tmp
sudo chown -R zou:www-data /opt/zou/tmp

#Prepare database------------------------------------------------------

#Create Zou database in postgres:
sudo su -l postgres
#psql -c 'create database zoudb;' -U postgres

#Set a password for your postgres user. For that start the Postgres CLI:
#psql

#Then set the password (mysecretpassword if you want to do some tests).
#psql -U postgres -d postgres -c "alter user postgres with password 'mysecretpassword';"
#type exit twice 
#Finally, create database tables (it is required to leave the posgres console and to activate the Zou virtual environment):
sudo -u zou DB_PASSWORD=yourdbpassword /opt/zou/zouenv/bin/zou init-db

#Prepare the key value store------------------------------------------

#background saving success rate, you can add this to /etc/sysctl.conf:
echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf

#Configure Gunicorn---------------------------------------------------

#Configure main API server
sudo mkdir /etc/zou

#WSGI server that will run zou as a daemon. Let's write the gunicorn configuration:
#Path: /etc/zou/gunicorn.conf
echo "
accesslog = "/opt/zou/logs/gunicorn_access.log"
errorlog = "/opt/zou/logs/gunicorn_error.log"
workers = 3
worker_class = "gevent" " >> /etc/zou/gunicorn.conf

#Let's create the log folder:
sudo mkdir /opt/zou/logs
sudo chown zou: /opt/zou/logs

#Then we daemonize the gunicorn process via Systemd. For that we add a new file that will add a new daemon to be managed by Systemd:
#Path: /etc/systemd/system/zou.service
#Please note that environment variables are positioned here. DB_PASSWORD must be set with your database password. SECRET_KEY must be generated randomly (use pwgen 16 command for t
echo "
[Unit]
Description=Gunicorn instance to serve the Zou API
After=network.target

[Service]
User=zou
Group=www-data
WorkingDirectory=/opt/zou
# Append DB_USERNAME=username DB_HOST=server when default values aren't used
# ffmpeg must be in PATH
Environment="DB_PASSWORD=yourdbpassword"
Environment="SECRET_KEY=yourrandomsecretkey"
Environment="PATH=/opt/zou/zouenv/bin:/usr/bin"
Environment="PREVIEW_FOLDER=/opt/zou/previews"
Environment="TMP_DIR=/opt/zou/tmp"
ExecStart=/opt/zou/zouenv/bin/gunicorn  -c /etc/zou/gunicorn.conf -b 127.0.0.1:5000 zou.app:app

[Install]
WantedBy=multi-user.target " >> /etc/systemd/system/zou.service

#Configure Events Stream API server
#Path: /etc/zou/gunicorn-events.conf
echo "
accesslog = "/opt/zou/logs/gunicorn_events_access.log"
errorlog = "/opt/zou/logs/gunicorn_events_error.log"
workers = 1
worker_class = "geventwebsocket.gunicorn.workers.GeventWebSocketWorker" " >> /etc/zou/gunicorn-events.conf

#Then we daemonize the gunicorn process via Systemd:
#Path: /etc/systemd/system/zou-events.service
echo "
[Unit]
Description=Gunicorn instance to serve the Zou Events API
After=network.target

[Service]
User=zou
Group=www-data
WorkingDirectory=/opt/zou
# Append DB_USERNAME=username DB_HOST=server when default values aren't used
Environment="PATH=/opt/zou/zouenv/bin"
Environment="SECRET_KEY=yourrandomsecretkey" # Same one than zou.service
ExecStart=/opt/zou/zouenv/bin/gunicorn -c /etc/zou/gunicorn-events.conf -b 127.0.0.1:5001 zou.event_stream:app

[Install]
WantedBy=multi-user.target " >> /etc/systemd/system/zou-events.service

#Configure Nginx-----------------------------------------------------------------------------------
#Finally we serve the API through a Nginx server. For that, add this configuration file to Nginx to redirect the traffic to the Gunicorn servers:
#Path: /etc/nginx/sites-available/zou
echo "
server {
    listen 80;
    server_name server_domain_or_IP;

    location /api {
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_pass http://localhost:5000/;
        client_max_body_size 500M;
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        send_timeout 600s;
    }

    location /socket.io {
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_pass http://localhost:5001;
    }
} " >> /etc/nginx/sites-available/zou

#Finally, make sure that default configuration is removed:
sudo rm /etc/nginx/sites-enabled/default

#We enable that Nginx configuration with this command:
sudo ln -s /etc/nginx/sites-available/zou /etc/nginx/sites-enabled

#Finally we can start our daemon and restart Nginx:
sudo systemctl enable zou
sudo systemctl enable zou-events
sudo systemctl start zou
sudo systemctl start zou-events
sudo systemctl restart nginx

#Update-----------------------------------------------------------------

#First, you have to upgrade the zou package:
cd /opt/zou
sudo /opt/zou/zouenv/bin/pip3 install --upgrade zou

#Then, you need to upgrade the database schema:
cd /opt/zou
sudo -u zou DB_PASSWORD=yourdbpassword /opt/zou/zouenv/bin/zou upgrade-db

#Finally, restart the Zou service:
sudo chown -R zou:www-data .
sudo systemctl restart zou
sudo systemctl restart zou-events

#NB: Make it sure by getting the API version number from https://myzoudomain.com/api.

#Deploying Kitsu----------------------------------------------------------
cd /opt/
sudo git clone -b build https://github.com/cgwire/kitsu
cd kitsu
git config --global --add safe.directory /opt/kitsu
sudo git config --global --add safe.directory /opt/kitsu
sudo git checkout build

#Then we need to adapt the Nginx configuration to allow it to serve it properly:
cat /dev/null > /etc/nginx/sites-available/zou
echo "
server {
    listen 80;
    server_name server_domain_or_IP;

    location /api {
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Host $host;
        proxy_pass http://localhost:5000/;
        client_max_body_size 500M;
        proxy_connect_timeout 600s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        send_timeout 600s;
    }

    location /socket.io {
        proxy_http_version 1.1;
	        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_pass http://localhost:5001;
    }

    location / {
        autoindex on;
        root  /opt/kitsu/dist;
        try_files $uri $uri/ /index.html;
    }
} " >> /etc/nginx/sites-available/zou

#Restart your Nginx server:
sudo systemctl restart nginx

#Update Kitsu

cd /opt/kitsu
sudo git reset --hard
sudo git pull --rebase origin build
