<p align="center"><img src="https://camo.githubusercontent.com/5ceadc94fd40688144b193fd8ece2b805d79ca9b/68747470733a2f2f6c61726176656c2e636f6d2f6173736574732f696d672f636f6d706f6e656e74732f6c6f676f2d6c61726176656c2e737667"></p>

[![Build Status](https://travis-ci.org/ElfSundae/sync-laravel.com.svg?branch=master)](https://travis-ci.org/ElfSundae/sync-laravel.com)

Quickly create a local mirror of [laravel.com](https://laravel.com) website, and keep Laravel documentation up to date.

## Requirements

- PHP >= 7.0.0
- `wget`
- `git`
- `composer`
- `npm` or `yarn`
- `gulp`

## Installation

```sh
wget https://raw.githubusercontent.com/ElfSundae/sync-laravel.com/master/sync-laravel.com
chmod +x sync-laravel.com
./sync-laravel.com -h
```

Upgrade this script:

```sh
./sync-laravel.com upgrade
```

## Usage

Simply pass the root path of your mirror to the script:

```sh
./sync-laravel.com /your/webroot/laravel.com
```

Then you can run `php artisan serve` to serve the mirror. Or the best practice is creating a virtual host configuration on your web server. And you may add a cron-job to keep your local mirror up to date with laravel.com.

You may use `-h` option to see the full usage:

```
Usage: sync-laravel.com <webroot> [<options>]

Options:
    upgrade             Upgrade this script
    status              Check status of webroot and docs
    skip-docs           Skip building docs
    skip-api            Skip building api documentation
    local-cdn           Download static files from CDN, and host them locally
    --font-format=FMT   Use FMT when downloading Google Fonts
                        Supported: eot, ttf, svg, woff, woff2
                        Default format is woff2
    --title=TXT         Replace page title to TXT
    china-cdn           Replace CDN hosts with China mirrors
    --gaid=GID          Replace Google Analytics tracking ID with GID
    remove-ga           Remove Google Analytics
    remove-ads          Remove advertisements
    clean               Clean webroot
    --version           Print version of this script
    -h, --help          Show this help
```

## Example Nginx Server Configuration

```nginx
server {
    listen      80;
    server_name laravel.com www.laravel.com;
    return      301 https://laravel.com$request_uri;
}

server {
    listen      443 ssl http2;
    server_name laravel.com;
    root        /data/www/laravel.com/public;
    add_header  Strict-Transport-Security "max-age=31536000" always;

    rewrite ^/((?!api).+)/$ /$1 permanent;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass    127.0.0.1:9000;
        fastcgi_index   index.php;
        fastcgi_param   SCRIPT_FILENAME  $document_root$fastcgi_script_name;
        include         fastcgi_params;
    }

    ssl_certificate     /usr/local/etc/nginx/certs/server.crt;
    ssl_certificate_key /usr/local/etc/nginx/certs/server.key;
}
```

## License

The MIT License.
