CREATE TABLE IF NOT EXISTS `salary` (
    `citizenid` VARCHAR(50) NOT NULL,
    `hourlyBalance` DECIMAL(10, 2) NOT NULL DEFAULT 0.00,
    `count` INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
