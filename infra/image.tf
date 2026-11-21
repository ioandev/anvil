# Flatcar publishes an official Scaleway qcow2, but not in the Scaleway
# marketplace: it has to be uploaded to Object Storage, imported as an l_ssd
# snapshot, and wrapped in an instance image.
#
# This whole chain is only needed to CREATE the server (its root volume is an
# independent copy). Once the server is up, `make cleanup` sets
# image_pipeline=false and destroys all four resources; re-enable before any
# server replacement.

resource "random_id" "bucket_suffix" {
  byte_length = 3
}

resource "scaleway_object_bucket" "flatcar" {
  count  = var.image_pipeline ? 1 : 0
  name   = "${var.bucket_name}-${random_id.bucket_suffix.hex}"
  region = var.region
}

resource "scaleway_object" "flatcar_qcow2" {
  count  = var.image_pipeline ? 1 : 0
  bucket = scaleway_object_bucket.flatcar[0].name
  region = var.region
  key    = "flatcar_production_scaleway_image.qcow2"
  file   = var.image_path
  # fileexists() guard keeps validate/plan working before `make fetch`
  hash = fileexists(var.image_path) ? filemd5(var.image_path) : null
}

resource "scaleway_instance_snapshot" "flatcar" {
  count = var.image_pipeline ? 1 : 0
  name  = "flatcar-stable"
  zone  = var.zone
  type  = "l_ssd"

  import {
    bucket = scaleway_object.flatcar_qcow2[0].bucket
    key    = scaleway_object.flatcar_qcow2[0].key
  }
}

resource "scaleway_instance_image" "flatcar" {
  count          = var.image_pipeline ? 1 : 0
  name           = "flatcar-stable"
  zone           = var.zone
  root_volume_id = scaleway_instance_snapshot.flatcar[0].id
  architecture   = "x86_64"
}
