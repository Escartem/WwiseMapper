# wwisemap

Builds the `.map` files AnimeWwise uses to turn hashed wwise `.wem` names back into real paths.

## Build

```
zig build -Doptimize=ReleaseFast
```

## Usage

Game has v1 or v2 db, v1 means it's auto fetched for excels dumps, v2 means it's obtained via other means (tsv or txt path list for example). Star rail is v1, Genshin is v2 since 5.5, Zenless is v2 since 2.3, Endfield is v1.

Example for hsr :
```
wwisemap update -g hkrpg -v 4.6 # update to latest
wwisemap build -g hkrpg -v 4.6 # make map
```

Example for genshin :
```
wwisemap update -g hk4e -v 7.1 -p known_filenames_7.1.txt # update v2 db from external source
wwisemap build -g hk4e -v 7.1 -d v2 # build map
```

Full trip for v1 db :
```
wwisemap fetch -g hkrpg # fetch config
wwisemap parse -g hkrpg # parse config into path list
wwisemap append -g hkrpg -v 4.6 # add new paths into the db
```

## Format for db

When adding data to the db it must be formatted to a json file with a list of paths, each path must :
- not have the language prefix
- use 2 backwards slashes (ideally)
- have the .wem extension at the end

The v1 parser does it automatically, for v2 and external sources it will try its best to convert to this format

## Contribute

If you add more data, feel free to open a PR with the updated db file :)

## Credits

- [Umai](http://github.com/umaichanuwu) - bug fixing and hash updates
- [MimieMethod](https://github.com/MiemieMethod) - better star rail parsing
- [Eleiyas](https://github.com/eleiyas) - ZZZ hashes
- [Ninjamask](https://github.com/ninjamask) - Genshin 6.7+ hashes
