<p align="center"><img src="https://camo.githubusercontent.com/5ceadc94fd40688144b193fd8ece2b805d79ca9b/68747470733a2f2f6c61726176656c2e636f6d2f6173736574732f696d672f636f6d706f6e656e74732f6c6f676f2d6c61726176656c2e737667"></p>

[![Build Status](https://travis-ci.org/ElfSundae/sync-laravel.com.svg?branch=master)](https://travis-ci.org/ElfSundae/sync-laravel.com)

Quickly create a local mirror of [laravel.com](https://laravel.com) website, and keep Laravel documentation up to date.

## Installation

```sh
wget https://raw.githubusercontent.com/ElfSundae/sync-laravel.com/master/sync-laravel.com
chmod +x sync-laravel.com
```

## Usage

Simply pass the root path of your mirror to the script:

```sh
./sync-laravel.com /your/webroot/laravel.com
```

Then you can run `php artisan serve` to serve the mirror. Or the best practice is creating a virtual host configuration on your web server. And you may add a cron-job to keep your local mirror up to date with laravel.com.

You may use `-h` option to see the full usage:

```sh
$ ./sync-laravel.com -h
Sync local mirror of laravel.com website. v1.0.0

Usage: sync-laravel.com <webroot> [<options>]

Options:
    --status        Check status
    --skip-docs     Skip building Laravel docs
    --skip-api      Skip building Laravel api
    --clean         Clean webroot
    -h, --help      Show this help
```

## License

The MIT License.
