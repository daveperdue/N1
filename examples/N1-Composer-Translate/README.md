
## Translate

A package for N1 that translates draft text into other languages using the Yandex Translation API.

<img src="https://raw.githubusercontent.com/nylas/N1/master/examples/N1-Composer-Translate/examples-screencap-translate.png"/>

#### Install this plugin

1. Download and run N1

2. From the menu, select `Developer > Install a Plugin Manually...`
   The dialog will default to this examples directory. Just choose the
   `N1-Composer-Translate` folder to install it!

   > When you install packages, they're moved to `~/.nylas/packages`,
   > and N1 runs `apm install` on the command line to fetch dependencies
   > listed in the package's `package.json`

#### Build documentation

```
cjsx-transform lib/main.cjsx > docs/main.coffee
docco docs/main.coffee
rm docs/main.coffee
```
