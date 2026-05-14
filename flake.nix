{
  description = "A Rust development environment";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { nixpkgs, flake-utils, rust-overlay, ... }:
    with flake-utils.lib; eachSystem ["x86_64-linux" "aarch64-darwin"] (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      };
      rustToolchain = pkgs.rust-bin.stable.latest.default.override {
        extensions = [ "rust-src" "rust-analyzer" "clippy" "rustfmt" ];
      };
    in {
      devShells.default =
        pkgs.mkShell {
          buildInputs = [
            rustToolchain
            pkgs.pkg-config
            pkgs.llvmPackages.libclang.lib
            pkgs.linuxHeaders
          ];
          RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
          BINDGEN_EXTRA_CLANG_ARGS = "-isystem ${pkgs.linuxHeaders}/include";
          # Remove the auto-generated rpath entry that contains the project path.
          # This breaks linking when the project path contains spaces.
          shellHook = ''
            export NIX_LDFLAGS="$(echo "$NIX_LDFLAGS" | sed 's|-rpath.*outputs/out/lib||')"
          '';
      };
    });
}
