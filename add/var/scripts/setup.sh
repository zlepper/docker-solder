#!/bin/sh

# Postgres setup
mkdir -p "$PGDATA"
chmod 700 "$PGDATA"
chown -R postgres "$PGDATA" 
mkdir /run/postgresql
chmod 700 /run/postgresql/
chown -R postgres /run/postgresql/

if [ -z "$(ls -A "$PGDATA")" ]; then
    gosu postgres initdb
    sed -ri "s/^#(listen_addresses\s*=\s*)\S+/\1'*'/" "$PGDATA"/postgresql.conf

    : ${POSTGRES_USER:="postgres"}
    : ${POSTGRES_DB:=$POSTGRES_USER}

    if [ "$POSTGRES_PASSWORD" ]; then
      pass="PASSWORD '$POSTGRES_PASSWORD'"
      authMethod=md5
    else
      echo "==============================="
      echo "!!! Use \$POSTGRES_PASSWORD env var to secure your database !!!"
      echo "==============================="
      pass=
      authMethod=trust
    fi
    echo


    if [ "$POSTGRES_DB" != 'postgres' ]; then
      createSql="CREATE DATABASE $POSTGRES_DB;"
      echo $createSql | gosu postgres postgres --single -jE
      echo
    fi

    if [ "$POSTGRES_USER" != 'postgres' ]; then
      op=CREATE
    else
      op=ALTER
    fi

    userSql="$op USER $POSTGRES_USER WITH SUPERUSER $pass;"
    echo $userSql | gosu postgres postgres --single -jE
    echo

    # internal start of server in order to allow set-up using psql-client
    # does not listen on TCP/IP and waits until start finishes
    gosu postgres pg_ctl -D "$PGDATA" -o "-c listen_addresses=''" -w start

    gosu postgres pg_ctl -D "$PGDATA" -m fast -w stop

    { echo; echo "host all all 0.0.0.0/0 $authMethod"; } >> "$PGDATA"/pg_hba.conf
fi

# Start postgres as a background service
gosu postgres postgres &

mkdir /var/www/technicsolder/app/storage/meta \
      /var/www/technicsolder/app/storage/views \
      /var/www/technicsolder/app/storage/sessions \
      /var/www/technicsolder/app/storage/resources \
      /var/www/technicsolder/app/storage/logs \
      /var/www/technicsolder/app/storage/github-api-cache \
      /var/www/technicsolder/app/storage/debugbar \
      /var/www/technicsolder/app/storage/cache

repoUrl="http://$REPO_HOST/"
echo "$repoUrl" 
### Solder setup
echo "Configuring solder"
cd /var/www/technicsolder
# Change to use postgres for the database
sed -i.bak -E "s!('default' => )'\w+'!\1'pgsql'!g" app/config/database.php
sed -i.bak -E "s!('database' => )'\w+'!\1'$POSTGRES_DB'!" app/config/database.php
sed -i.bak -E "s!('username' => )'\w+'!\1'$POSTGRES_USER'!" app/config/database.php
sed -i.bak -E "s!('password' => )''!\1'$POSTGRES_PASSWORD'!" app/config/database.php
# Setup file storage
sed -i.bak -E "s!('repo_location' => )''!\1'/var/www/repo.solder/'!" app/config/solder.php
sed -i.bak -E "s!('mirror_url' => )''!\1'$REPO_HOST'!" app/config/solder.php
# Setup the solder app
sed -i.bak -E "s!('url' => )'http://solder\.app:8000'!\1'$repoUrl'!" app/config/app.php
# Hack for php7.1 not liking mcrypt
sed -i.bak -E "2s/\s?/error_reporting(E_ALL ^ E_DEPRECATED);/" app/config/app.php

echo "Running php artisan migrate:install"
# Setup the database data
php artisan migrate:install
echo "Running actual migration"
php artisan --force migrate

# Start php
mkdir /var/run/php
sed -i.bak "s|;*daemonize\s*=\s*yes|daemonize = yes|g" /etc/php7/php-fpm.conf
sed -i.bak "s|;*listen\s*=\s*127.0.0.1:9000|listen = /var/run/php/php-fpm.sock|g" /etc/php7/php-fpm.d/www.conf
sed -i.bak "s|;*listen.owner\s*=\s*nobody|listen.owner = nginx|g" /etc/php7/php-fpm.d/www.conf
sed -i.bak "s|;*listen.group\s*=\s*nobody|listen.group = nginx|g" /etc/php7/php-fpm.d/www.conf
/usr/sbin/php-fpm7

# Setup solder website
mkdir /var/log/nginx/technicsolder
mkdir /run/nginx
sed -i.bak -E "s!ENV_SOLDER_HOST!$SOLDER_HOST!g" /etc/nginx/conf.d/technicsolder.conf

## Setup file repo
# Create user
mkdir /var/www/repo.solder
chmod -R 777 /var/www/repo.solder
# Setup file webserver
mkdir /var/log/nginx/repo.solder
sed -i.bak -E "s!ENV_REPO_HOST!$REPO_HOST!g" /etc/nginx/conf.d/repo.conf

## Setup GFS
gfs -persist -username "$REPO_USER" -password "$REPO_PASSWORD" -serve /var/www/repo.solder
# Run gfs
gfs &

# Start webserver
echo "Starting nginx"
nginx