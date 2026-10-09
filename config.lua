Config = {}

Config.DevMode = false
Config.Notify = true

-- Collection
Config.PayoutAccount = 'cash' -- RSG money account
Config.AutoCollect = true
Config.CollectCommand = {
    Enabled = true,
    Name = 'collect', -- Without /
    Permission = 'user',
}

-- Timing in milliseconds
Config.PayoutInterval = 60 * 1000
Config.CheckInterval = 60 * 1000
Config.CollectCooldown = 5 * 1000
Config.BalanceCooldown = 2 * 1000

-- Rates and balance cap
Config.PayoutPerInterval = 12.50 -- Fallback for unlisted jobs and grades
Config.Cap = 50.00 -- Uncollected balance; 0 = unlimited
Config.RequireDuty = false

-- RSG job names and grade levels; a rate of 0 disables accrual.
Config.Jobs = {
    -- unemployed = { [0] = 12.50 },
    -- vallaw = {
    --     [0] = 12.50,
    --     [1] = 15.00,
    --     [2] = 20.00,
    -- },
}

-- Lifetime accrual limits. Both groups share one counter; 0 = unlimited.
Config.CountCaps = {
    Citizen = 0,
    Outlaw = 0,
}
Config.OutlawStatusThreshold = 100 -- players.outlawstatus
