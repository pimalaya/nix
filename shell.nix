{ nixpkgs ? <nixpkgs>
, system ? builtins.currentSystem
, pkgs ? import nixpkgs { inherit system; }
, languageServer ? "nixd"
, codeFormatter ? "nixfmt"
}:

pkgs.mkShell {
  buildInputs = pkgs.lib.attrVals [ languageServer codeFormatter ] pkgs;
}
