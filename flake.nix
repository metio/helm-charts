# SPDX-FileCopyrightText: The helm-charts Authors
# SPDX-License-Identifier: 0BSD

# The single source of the chart-authoring toolchain: CI and local shells run
# every gate through this flake's devShell, so both use the exact tool versions
# pinned in flake.lock. The shared lint gate, helm-schema, and the org-wide
# nixpkgs pin come from the metio/ci flake; Renovate keeps the lock fresh. No Go
# build toolchain — charts reference images built in the source repos, they don't
# compile anything. The kind-cluster smoke gates (operator-smoke, stageset-smoke)
# build real clusters and stay on the runner's docker/kind, not the devShell.
{
  description = "helm-charts development environment";

  inputs = {
    devshell.url = "github:metio/nix-devshell";
    nixpkgs.follows = "devshell/nixpkgs";
    flake-compat.follows = "devshell/flake-compat";
  };

  outputs =
    {
      self,
      nixpkgs,
      devshell,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (
        pkgs:
        let
          # helm v4 wrapped with the unittest plugin (per-template assertions +
          # snapshots). wrapHelm installs the plugin into the wrapper, so
          # `helm unittest` works without a separate plugin-install step.
          helm = pkgs.wrapHelm pkgs.kubernetes-helm {
            plugins = [ pkgs.kubernetes-helmPlugins.helm-unittest ];
          };

          # helm-schema (the values.schema.json generator) comes from the shared
          # metio/ci flake, which builds it from source and keeps it current.
          helm-schema = devshell.lib.helm-schema pkgs;

          # The chart toolchain the gates and the release pipeline drive.
          chartTools = [
            helm
            helm-schema
          ]
          ++ (with pkgs; [
            helm-docs # regenerate each chart README from its .gotmpl
            chart-testing # ct lint + install
            kube-score # static analysis on rendered manifests
            kubeconform # validate rendered manifests against k8s schemas
            python3Packages.yamale # ct lint shells out to it for Chart.yaml schemas
            yq-go # inject artifacthub.io/changes into Chart.yaml at release
            git-cliff # per-chart, path-scoped release notes
            cosign # keyless sign/verify the pushed OCI charts
            jq
          ]);

          # Multi-step gate + pipeline commands: plain scripts/<name>.sh that nix
          # wraps with `set -euo pipefail`, shellchecks at build, and runs with
          # hermetic runtimeInputs. On PATH inside `nix develop`, callable as
          # `nix develop --command <name>`.
          chart-static = pkgs.writeShellApplication {
            name = "chart-static";
            runtimeInputs = [
              helm
            ]
            ++ (with pkgs; [
              chart-testing
              helm-docs
              kube-score
              kubeconform
              yamllint
              python3Packages.yamale
              coreutils
            ]);
            text = builtins.readFile ./scripts/chart-static.sh;
          };
          release-charts = pkgs.writeShellApplication {
            name = "release-charts";
            runtimeInputs = [
              helm
              helm-schema
            ]
            ++ (with pkgs; [
              helm-docs
              git-cliff
              yq-go
              cosign
              gh
              git
              gnugrep
              gnused
              coreutils
            ]);
            text = builtins.readFile ./scripts/release-charts.sh;
          };
          sync-joi = pkgs.writeShellApplication {
            name = "sync-joi";
            runtimeInputs = [
              helm
              helm-schema
            ]
            ++ (with pkgs; [
              curl
              gawk
              git
              coreutils
            ]);
            text = builtins.readFile ./scripts/sync-joi.sh;
          };
          commands = [
            chart-static
            release-charts
            sync-joi
          ];
        in
        {
          default = devshell.lib.mkDevShell {
            inherit pkgs;
            packages = chartTools ++ commands;
            menu = ''
              echo "helm-charts commands: chart-static <chart>, release-charts, sync-joi."
              echo "  Tools: helm (with unittest), ct, kube-score, kubeconform, helm-docs,"
              echo "  helm-schema, yamale, yq, git-cliff, cosign."
            '';
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
