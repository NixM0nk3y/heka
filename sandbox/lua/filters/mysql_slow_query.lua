-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

--[[
Graphs MySQL slow query data produced by the :ref:`config_mysql_slow_query_log_decoder`.

Config:

- sec_per_row (uint, optional, default 60)
    Sets the size of each bucket (resolution in seconds) in the sliding window.

- rows (uint, optional, default 1440)
    Sets the size of the sliding window i.e., 1440 rows representing 60 seconds
    per row is a 24 sliding hour window with 1 minute resolution.

- anomaly_config(string) - (see :ref:`sandbox_anomaly_module`)

*Example Heka Configuration*

.. code-block:: ini

    [Sync-1_5-SlowQueries]
    type = "SandboxFilter"
    script_type = "lua"
    message_matcher = "Logger == 'Sync-1_5-SlowQuery'"
    ticker_interval = 60
    filename = "lua_filters/mysql_slow_query.lua"

        [Sync-1_5-SlowQueries.config]
        anomaly_config = 'mww_nonparametric("Statistics", 4, 15, 10, 0.8)'
--]]

require "circular_buffer"
local alert         = require "alert"
local annotation    = require "annotation"
local anomaly       = require "anomaly"

local title             = "Statistics"
local rows              = read_config("rows") or 1440
local sec_per_row       = read_config("sec_per_row") or 60
local anomaly_config    = anomaly.parse_config(read_config("anomaly_config"))
annotation.set_prune(title, rows * sec_per_row * 1e9)

data = circular_buffer.new(rows, 4, sec_per_row)
sums = circular_buffer.new(rows, 3, sec_per_row)
local QUERY_TIME    = data:set_header(1, "Query Time", "s", "none")
local LOCK_TIME     = data:set_header(2, "Lock Time", "s", "none")
local RESPONSE_SIZE = data:set_header(3, "Response Size", "B", "none")
local COUNT         = data:set_header(4, "Count")

function process_message ()
    local ns = read_message("Timestamp")
    local cnt = data:add(ns, COUNT, 1)
    if not cnt then return 0 end

    local qt = read_message("Fields[Query_time]")
    local lt = read_message("Fields[Lock_time]")
    local bs = read_message("Fields[Bytes_sent]")
    data:set(ns, QUERY_TIME, sums:add(ns, QUERY_TIME, qt)/cnt)
    data:set(ns, LOCK_TIME, sums:add(ns, LOCK_TIME, lt)/cnt)
    data:set(ns, RESPONSE_SIZE, sums:add(ns, RESPONSE_SIZE, bs)/cnt)
    return 0
end

function timer_event(ns)
    if anomaly_config then
        if not alert.throttled(ns) then
            local msg, annos = anomaly.detect(ns, title, data, anomaly_config)
            if msg then
                annotation.concat(title, annos)
                alert.send(ns, msg)
            end
        end
        output({annotations = annotation.prune(title, ns)}, data)
        inject_message("cbuf", title)
    else
        inject_message(data, title)
    end
end
