{
  description = "Personal Agent Skills, installable via npx skills (skills.sh)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      # Environment for developing and TESTING the skills in this repo.
      #
      # tmux is here because the fzf review flow of agent-session-batch-export
      # needs a real PTY to be tested honestly: `--ui tsv` can be exercised by
      # piping, but the interactive path only proves itself under a terminal you
      # can drive and read back (tmux send-keys + capture-pane).
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.tmux
          pkgs.shellcheck
        ];
      };
    };
}
