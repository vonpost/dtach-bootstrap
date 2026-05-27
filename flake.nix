{
  description = "Build a Linux x86_64 dtach binary for dtach-bootstrap.el";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      forAllSystems = f:
        nixpkgs.lib.genAttrs systems
          (system:
            f (import nixpkgs {
              inherit system;
              crossSystem = {
                config = "x86_64-unknown-linux-musl";
              };
            }));
    in
    {
      packages = forAllSystems (pkgs: {
        dtach-x86_64-linux = pkgs.pkgsStatic.dtach;
        default = pkgs.pkgsStatic.dtach;
      });
    };
}
