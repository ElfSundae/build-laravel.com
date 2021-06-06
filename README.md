<p align="center">
    <a href="https://laravel.0x123.com" target="_blank">
        <img src="https://raw.githubusercontent.com/ElfSundae/laravel.com/master/public/assets/img/components/logo-laravel.svg">
    </a>
</p>

[![tests](https://github.com/ElfSundae/build-laravel.com/actions/workflows/tests.yml/badge.svg)](https://github.com/ElfSundae/build-laravel.com/actions/workflows/tests.yml)

A rapid way to build mirror of [laravel.com](https://laravel.com) website, and keep Laravel documentation up to date.

[:cn: 中国镜像](https://github.com/ElfSundae/laravel.com)

## Requirements

- PHP 7 / 8
- `wget`
- `git`
- `composer`
- `npm` or `yarn`

## Installation

```sh
$ wget https://raw.githubusercontent.com/ElfSundae/build-laravel.com/master/build-laravel.com
$ chmod +x build-laravel.com
```

Upgrade this script:

```sh
$ build-laravel.com upgrade
```

## Usage

Simply pass the root path to the script:

```sh
$ build-laravel.com /data/www/laravel.com
```

Then you may run `$ php artisan serve` to serve your mirror, or configure a virtual host on your web server. And you may add a cron-job to keep your mirror up to date.

You can use `-h` option to see the full usage:

```
Usage: build-laravel.com <webroot> [options]

Options:
    status              Check status of webroot and docs
    clean               Clean webroot
    local-cdn           Host CDN files locally
    china-cdn           Replace CDN hosts with China mirrors
    remove-ga           Remove Google Analytics
    remove-ads          Remove advertisements
    cache               Create website cache
    skip-docs           Skip updating docs
    skip-api            Skip building API documentation
    skip-update-app     Skip updating app: git-pull repository, install PHP and Node packages,
                        process views, compile assets, etc
    upgrade             Upgrade this script
    --root-url=URL      Set the root URL of website: APP_URL env variable
    --title=TXT         Replace page title to TXT
    --gaid=GID          Replace Google Analytics tracking ID with GID
    --font-format=FMT   Use FMT when downloading Google Fonts, default is woff2
                        Supported: eot, ttf, svg, woff, woff2
    -f, --force         Force build
    -v, --version       Print version of this script
    -h, --help          Show this help
```

## License

The [MIT License](LICENSE.md).
