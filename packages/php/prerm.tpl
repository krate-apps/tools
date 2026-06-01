#!/bin/sh
set -e

case "$1" in
    remove|purge)
    update-alternatives --remove php     /usr/local/bin/php@VERSION@      || true
    update-alternatives --remove php-fpm /usr/local/sbin/php-fpm@VERSION@ || true
    ;;
esac

exit 0
