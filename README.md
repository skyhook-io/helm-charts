## Usage

[Helm](https://helm.sh) must be installed to use the charts.  Please refer to
Helm's [documentation](https://helm.sh/docs) to get started.

Once Helm has been set up correctly, add the repo as follows:

  helm repo add skyhook https://skyhook-io.github.io/helm-charts

If you had already added this repo earlier, run `helm repo update` to retrieve
the latest versions of the packages.  You can then run `helm search repo
skyhook` to see the charts.

To install the skyhook-agent chart:

    helm install skyhook-agent skyhook/skyhook-agent

To uninstall the chart:

    helm delete skyhook-agent

