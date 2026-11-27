# Documentation

The reference guide is written in AsciiDoc. Assemblies live in
[`assemblies/`](assemblies/), and the modules they include live in
[`modules/`](modules/). The build script renders the assemblies to HTML under
[`build/`](build/).

## Build locally

Use the Asciidoctor container image:

```bash
podman run --rm -v "$PWD":/documents -w /documents \
    --security-opt label=disable \
    --user "$(id -u):$(id -g)" \
    docker.io/asciidoctor/docker-asciidoctor:latest ./hack/build-docs.sh
```

The rendered entry point is [`build/index.html`](build/index.html). Re-run the
build after changing an assembly or module.

## Preview locally

Serve the rendered site with Python:

```bash
python3 -m http.server --directory docs/build 8000
```

Then open <http://localhost:8000>.

### Open the html file

Alternatively, you can always just open the HTML file:
```bash
xdg-open docs/build/index.html
```
