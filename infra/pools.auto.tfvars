# Node pools and the k6 machine (infra/pools.tf). Committed: no secrets here. scripts/pool edits the counts, types and
# direct flags; never change a type here by hand for a pool that is up without the owner's yes (CLAUDE.md: a resize is a
# restart and a new billed hour). count 0 = nothing exists and nothing is billed.
pools = {
  demo = {
    count               = 0
    type                = "POP2-4C-16G"
    disk_gb             = 40
    swap_mb             = 1024
    direct              = false
  }
}

loadgen = { count = 0, type = "POP2-2C-8G" }

# The Flatcar image for pool nodes on block storage, imported the first time a pool or the k6 machine starts and kept.
pool_image_pipeline = false
