{ pkgs ? import <nixpkgs> {} } :

pkgs.kitty.overridePythonAttrs (old: old//{
  name = "grechanik-kitty";
  src = builtins.filterSource
    (path: type: type != "directory" || baseNameOf path != ".git")
    ./.;
  checkPhase = null;
})
