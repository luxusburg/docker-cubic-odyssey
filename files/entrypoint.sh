#!/bin/bash

# To be able to use the volumes user cubic needs access
sudo -u root chown -R cubic:cubic /home/cubic
exec "$@"
