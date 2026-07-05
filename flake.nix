# SPDX-FileCopyrightText: The helm-charts Authors
# SPDX-License-Identifier: 0BSD

# The single source of the chart-authoring toolchain: CI and local shells run
# every gate through this flake's devShell, so both use the exact tool versions
# pinned in flake.lock. Renovate keeps the lock fresh. No Go build toolchain —
# charts reference images built in the source repos, they don't compile
# anything. The kind-cluster smoke gates (operator-smoke, stageset-smoke) build
# real clusters and stay on the runner's docker/kind, not the devShell.
{
  description = "helm-charts development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-compat.url = "github:edolstra/flake-compat";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # dadav/helm-schema is not in nixpkgs; build it from source. It generates
      # each chart's values.schema.json from the `# @schema` annotations at
      # release time. Release tags carry no `v` prefix.
      helm-schema =
        pkgs:
        pkgs.buildGoModule rec {
          pname = "helm-schema";
          version = "0.23.4";
          src = pkgs.fetchFromGitHub {
            owner = "dadav";
            repo = "helm-schema";
            rev = version;
            hash = "sha256-btkkNzye9if4lF/YdhalbwA2/dcZArU6/9Hr0bTJf1M=";
          };
          vendorHash = "sha256-jbK+XD5CbjMQJUJCcKbNN8LhYuhuy+Z3XcCmgiYw25Y=";
        };
    in
    {
      packages = forAllSystems (pkgs: {
        helm-schema = helm-schema pkgs;
      });

      devShells = forAllSystems (
        pkgs:
        let
          # helm v4 wrapped with the unittest plugin (per-template assertions +
          # snapshots). wrapHelm installs the plugin into the wrapper, so
          # `helm unittest` works without a separate plugin-install step.
          helm = pkgs.wrapHelm pkgs.kubernetes-helm {
            plugins = [ pkgs.kubernetes-helmPlugins.helm-unittest ];
          };

          # The lint gate every metio repo shares byte-for-byte — lift into a
          # shared flake when the next repo needs the identical set.
          lintTools = with pkgs; [
            reuse
            typos
            yamllint
            actionlint
            shellcheck # actionlint shells out to it for run: blocks
            markdownlint-cli2
          ];

          # The chart toolchain the gates and the release pipeline drive.
          chartTools = [
            helm
            (helm-schema pkgs)
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
              (helm-schema pkgs)
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
              (helm-schema pkgs)
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
          default = pkgs.mkShell {
            packages = chartTools ++ lintTools ++ commands;
            shellHook = ''
              echo "helm-charts devshell — commands: chart-static <chart>, release-charts,"
              echo "  sync-joi. Tools: helm (with unittest), ct, kube-score, kubeconform,"
              echo "  helm-docs, helm-schema, yamale, yq, git-cliff, cosign,"
              echo "  plus the lint gate (reuse, typos, yamllint, actionlint, markdownlint)."
            '';
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
