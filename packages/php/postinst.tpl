#!/bin/sh
set -e

case "$1" in
    configure|abort-upgrade)
        update-alternatives --install /usr/bin/php     php     /usr/local/bin/php@VERSION@      100
        update-alternatives --install /usr/bin/php-fpm php-fpm /usr/local/sbin/php-fpm@VERSION@ 100
    ;;
    remove|purge)
        update-alternatives --remove php /usr/local/bin/php@VERSION@ || true
        update-alternatives --remove php-fpm /usr/local/sbin/php-fpm@VERSION@ || true
    ;;
esac

exit 0
