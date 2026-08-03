local addonName, ns = ...

ns.Data = ns.Data or {}

-- NOT YET GENERATED. The embellishment bonus IDs still have no established
-- derivation from DB2; see docs/superpowers/db2-schema-findings.md.
--
-- The table is deliberately left empty rather than filled with placeholders.
-- With placeholders nobody matches, so every player collects a confident
-- "0 of 2 embellishments" warning -- an ungenerated table producing a finding
-- someone could be called out over. Rules treats an empty table as "no data"
-- and stays silent, which is the only honest behaviour until this is real.
ns.Data.Embellishments = {}
