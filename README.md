# shade

A small collection of single-purpose libraries for [Odin](https://odin-lang.org),
in the spirit of Sean Barrett's [stb](https://github.com/nothings/stb): each one
is a self-contained package you can drop into a project and use on its own, with
no dependency on the rest of the collection. Take the one you need, leave the
rest.

Every library lives under `src/` as its own package and is documented by a
`README.md` next to the code.

---

## Libraries

| Library | Description |
|---|---|
| [`lane`](src/lane) | SPMD "run the same proc on every core" parallelism over fixed persistent threads, ISPC-style lanes. |

---

## Examples

Runnable demos live under `examples/`, each with its own `README.md`:

| Example | Description | Libraries used |
|---|---|---|
| [`galaxy`](examples/galaxy) | Interactive N-body galaxy: an O(n²) gravity sim running SPMD on all cores with a SIMD inner loop, drawn with SDL_gpu. | [`lane`](src/lane) |

---

## Usage

Point an Odin collection at `src/` and import the library you want, or just copy the files you want to your project:

```sh
odin build . -collection:shade=path/to/shade/src
```

```odin
import "shade:lane"

main :: proc() {
    lane.init()
    defer lane.deinit()
    // ...
}
```

Each library's `README.md` covers its API and usage.

---

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Fernando Nunes de Miranda
