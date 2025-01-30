# Production Podman setup for Otterwiki

## Overview of the production setup

The production setup is available on the [production_compose branch](https://github.com/mattock/otterwiki/tree/production_compose)
of https://github.com/mattock/otterwiki and will not work on vanilla Otterwiki.

The setup consists of three containers:

* **web:** uwsgi process that serves otterwiki
* **nginx:** reverse proxy for uwsgi
* **db:** postgresql database for otterwiki

In addition the *certbot* container image is launched to fetch new certbot
certificates. However, that container runs outside of the stack itself.

These containers are configured with environment files:

* **.env.prod.nginx:** configuration for nginx and Letsencrypt
* **.env.prod.db:** configuration for postgresql

There are four volumes:

* **db:** used by the db container
* **app-data:** configuration files for the web (otterwiki/uwsgi) container
* **static:** shared static data for web (rw) and nginx (ro) containers
* **letsencrypt:** certificates used by nginx (ro) container

This guide assumes that Letsencrypt certificates are used. However, there's no
inherent dependency on Letsencrypt: any commercial or self-signed certificates
can be used if one is so inclined. A certbot renewal script for Podman is
provided in *nginx/certbot-renew.sh*.

## Prerequisites

The container host needs several things in order to function properly:

* [Podman](https://podman.io/) and [podman-compose](https://github.com/containers/podman-compose) are installed
* User *otterwiki* is present
* Tool for modifying firewall configurations is available (iptables, ip6tables, firewalld, etc)
* TCP ports 80 and 443 are open on the container host
* TCP port 80 on the host redirects to port 8080 on the container host (for Letsencrypt)
* TCP port 443 on the host redirects to port 8443 on the container host (for web traffic)

The assumptions in this guide are the following:

* The container host is Ubuntu 24.04
* Podman is used to run the stack
* Otterwiki is cloned to /home/otterwiki/otterwiki
* Raw *iptables* and *ip6tables* are used to modify the firewall configuration
* All commands are run as *otterwiki* user unless implied otherwise by use of *sudo*

## Creating env files for the stack

The first step is to add two environment variable files under
*/home/otterwiki/otterwiki*.  The first is for the *db* container (postgresql):

```
# .env.prod.db
POSTGRES_PASSWORD=mypassword
POSTGRES_USER=otterwiki
POSTGRES_DB=otterwiki
```

The second is for *nginx*:

```
OTTERWIKI_DOMAIN=wiki.mydomain.com
OTTERWIKI_CONTEXT=/home/otterwiki/otterwiki
OTTERWIKI_VOLUME=otterwiki_letsencrypt
OTTERWIKI_CERTBOT_EMAIL=certbot@mydomain.com
```

With these in place you can build and start the Compose stack. The
*OTTERWIKI_CERTBOT_EMAIL* variable is only needed if you use Certbot. 

## Set up firewall on the container host

### Open HTTP and HTTPS ports in the firewall

Make sure that TCP ports 80 and 443 on the host's firewall are open. Otherwise
redirects (see below) won't be able to kick in. If you're using Docker with
default iptables rules you can probably skip this step.

If Otterwiki is running in a public Cloud you will need to open the ports in
the Cloud provider's firewall.

### Setting up firewall redirect rules

The Otterwiki Production Compose stack does not listen on any privileged ports
on the host. This is primarily to avoid having to run the Compose stack with
higher than necessary privileges. This has the side-effect that additional
configuration is required to enable HTTPS (to the nginx container) and HTTP
(for Letsencrypt) traffic to the containers.

You can use iptables rules to add the redirects. Replace ens5 below with the
primary interface of the Otterwiki server:

```
sudo iptables  -A PREROUTING -i ens5 -p tcp -m tcp --dport 80 -m comment --comment "900 enable letsencrypt renewals on ipv4" -j REDIRECT --to-ports 8080
sudo iptables  -A PREROUTING -i ens5 -p tcp -m tcp --dport 443 -m comment --comment "901 redirect HTTPS to container on ipv4" -j REDIRECT --to-ports 8443
sudo ip6tables -A PREROUTING -i ens5 -p tcp -m tcp --dport 80 -m comment --comment "900 enable letsencrypt renewals on ipv6" -j REDIRECT --to-ports 8080
sudo ip6tables -A PREROUTING -i ens5 -p tcp -m tcp --dport 443 -m comment --comment "901 redirect HTTPS to container on ipv6" -j REDIRECT --to-ports 8443
```

To make sure the iptables rules stick and don't get wiped out (e.g. by Docker):

```
sudo apt-get install netfilter-persistent
sudo systemctl enable netfilter-persistent.service
```

The same redirects can be done with firewalld as described
[here](https://major.io/p/forwarding-ports-with-firewalld). However, Docker
likes to manage the whole set of iptables rules so making it co-exist with
firewalld, ufw and such abstraction layers tends not to work that well. This is
not a problem if you run Otterwiki on podman-compose as Podman does not depend
on firewall rules for its networking.

## Letsencrypt setup

### Creating initial Letsencrypt certificates

Once the Otterwiki volumes and firewall redirects are present you can create the
initial Letsencrypt certificates:

```
cd /home/otterwiki/otterwiki/nginx
./certbot-renew.sh
```

This should generate fresh SSL certificates and save them to the
*otterwiki-letsencrypt* volume. The nginx container expects to find the full
certificate chain (chain + certificate) and the private key from the following
location:

    * /etc/letsencrypt/live/${OTTERWIKI_DOMAIN}/fullchain.pem;
    * /etc/letsencrypt/live/${OTTERWIKI_DOMAIN}/privkey.pem;

Replace *OTTERWIKI_DOMAIN* with the value you gave in *.env.prod.nginx*.

### Periodically renewing Letsencrypt certificates

You can use a systemd service to renew Otterwiki's
Letsencrypt certificates:

```
# /etc/systemd/system/otterwiki-letsencrypt-daily.service
[Service]
Type=oneshot
User=otterwiki
ExecStart=/home/otterwiki/otterwiki/nginx/certbot-renew.sh
WorkingDirectory=/home/otterwiki/otterwiki/nginx
```

To schedule daily renewal (renew only when needed) add a systemd timer:

```
# /etc/systemd/system/otterwiki-letsencrypt-daily.timer
[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
```

Copy the files to /etc/systemd/system and reload systemd units:

```
sudo systemctl daemon-reload
sudo systemctl enable otterwiki-letsencrypt-daily.service
sudo systemctl start otterwiki-letsencrypt-daily.service
```

The *certbot-renew.sh* script that the service runs autodetects Podman and
Docker. The former is preferred, if both are found. The script also restarts
the *nginx* container in the stack automatically *if* the certificate gets
updated.

# Using the production Compose stack

The first option is to run Otterwiki with podman-compose. This is useful when
developing the production setup. For production use we recommend using Podman
Quadlets, that is, running the Otterwiki containers as systemd services.

## Building the Compose stack

To build the Otterwiki compose stack do:

```
podman-compose -f docker-compose.prod.yml build
```

## Create the volumes

After you've built the containers you can bring up the stack to create the volumes:

```
podman-compose -f docker-compose.prod.yml up
```

The stack will *not* come up cleanly as the SSL certificates are missing. In
particular the *nginx* container will refuse to start, but that's ok for now.
Kill the stack with CTRL-C.

## Setting up systemd service for Otterwiki Production Compose stack

You can run Otterwiki Compose stack as a systemd service. Here's an example for
use with Docker:

```
# /etc/systemd/system/otterwiki.service
[Unit]
Description=Run otterwiki in docker compose

[Service]
Restart=on-failure
User=otterwiki
TimeoutStopSec=15
WorkingDirectory=/home/otterwiki/otterwiki
ExecStartPre=podman-compose -f docker-compose.prod.yml down
ExecStart=podman-compose -f docker-compose.prod.yml up
ExecStop=podman-compose -f docker-compose.prod.yml down

[Install]
WantedBy=multi-user.target
```

This systemd service will not work as-is on podman-compose. At minimum, you
need to remove the *Group* line and change instances of "docker compose" to
"podman-compose". If you use Podman you can run Otterwiki as a non-root user on
the host with minimal privileges, preferably with a user-specific systemd
service:

* https://www.baeldung.com/linux/systemd-create-user-services

**NOTE:** podman can get in a confused state when it runs as a non-root user in
and out of a user session. The symptoms are suggestions to run "podman system
renumber" and duplicate lockNumber values for various Podman resources upon
inspection. The issue seems to be that Podman stores it in different place
depending on how it was invoked, which can create duplicates. This issue is
known to affect the version of Podman included in Ubuntu 24.04, but may be
present in other versions as well.

## Starting the Otterwiki Production Compose stack

Once all the configuration is done, you can start the stack:

podman-compose -f docker-compose.prod.yml up

# Running Otterwiki in Podman Quadlets

Podman Quadlets are essentially Podman containers, volumes, networks, etc.
running under system. Systemd can handle some of the dependencies automatically.
A set of files is included under "quadlets" directory. Just copy them to

```
/etc/containers/systemd/users/UID/
```

where *UID* should match the uid of the *otterwiki* user on the container host.
Then you can start the services as the *otterwiki* user:

```
systemctl --user daemon-reload
systemctl --user enable otterwiki-db otterwiki-web otterwiki-nginx
systemctl --user start otterwiki-db otterwiki-web otterwiki-nginx
``` 

The volumes used by the Podman Quadlets setup do not overlap with those created
by the Podman Compose stack. You can easily identify them by their "systemd"
prefix.

Note that similarly to the podman-compose setup this will not work out of the
box, because SSL certificates are missing. Moreover, as Podman does not not run
as root, you will need to manually fix the permissions on all volumes so that
the user uwsgi (i.e. otterwiki) runs as has the privileges to read and/or write
to the volumes. This is easiest to do with "podman unshare" on the host as the
user as whom Otterwiki containers run. For example to allow uwsgi to write to
the Git repository:

    cd ~/.local/share/containers/storage/volumes/systemd-otterwiki-app_data/_data
    podman unshare chown -R www-data:www-data repository

# Configure Otterwiki to use postgresql instead of sqlite

By default Otterwiki is configured to use sqlite. To make it use postgresql
edit Otterwiki configuration file, *settings.cfg*, in the *app_data* volume.
The location of the file may vary:

* ~/.local/share/containers/storage/volumes/otterwiki\_app-data/\_data/settings.cfg (podman-compose)
* ~/.local/share/containers/storage/volumes/systemd-otterwiki-app\_data/\_data/settings.cfg (Podman Quadlets)

Make sure that the database connection string looks like this:

```
SQLALCHEMY_DATABASE_URI = 'postgresql://otterwiki:mypassword@db/otterwiki'
```

Where *mypassword* matches the value of *POSTGRES_PASSWORD* in *.env.prod.db*.

