<p align="center"><a href="https://laravel.0x123.com" target="_blank"><img src="https://laravel.0x123.com/assets/img/components/logo-laravel.svg"></a></p>

[![Build Status](https://img.shields.io/travis/ElfSundae/sync-laravel.com/master.svg?style=flat-square)](https://travis-ci.org/ElfSundae/sync-laravel.com)

Quickly create a local mirror of [laravel.com](https://laravel.com) website, and keep Laravel documentation up to date.

中国镜像：https://laravel.0x123.com

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
    --root-url=URL      Set the root URL of website
    skip-docs           Skip updating docs
    skip-api            Skip building api documentation
    local-cdn           Download static files from CDN, and host them locally
    --font-format=FMT   Use FMT when downloading Google Fonts
                        Supported: eot, ttf, svg, woff, woff2
                        Default is woff2
    --title=TXT         Replace page title to TXT
    china-cdn           Replace CDN hosts with China mirrors
    --gaid=GID          Replace Google Analytics tracking ID with GID
    remove-ga           Remove Google Analytics
    remove-ads          Remove advertisements
    cache               Create website cache
    clean               Clean webroot
    -f, --force         Force build
    --version           Print version of this script
    -h, --help          Show this help
```

## License

The MIT License.
