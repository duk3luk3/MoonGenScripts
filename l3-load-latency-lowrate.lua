local dpdk		= require "dpdk"
local memory	= require "memory"
local device	= require "device"
local ts		= require "timestamping"
local dpdkc		= require "dpdkc"
local filter	= require "filter"
local ffi		= require "ffi"
local histo = require "histogram"

function master(...)
	local txPort, rxPort, rate, size = tonumberall(...)
	if not txPort or not rxPort then
		errorf("usage: txPort rxPort [rate [size]]]")
	end
	rate = rate or 0.1
	size = (size or 128) - 4 -- 4 bytes off for crc
	printf("Rate setting: %f mpps", rate)
	local rxMempool = memory.createMemPool()
	if txPort == rxPort then
		txDev = device.config(txPort, rxMempool, 1, 1)
		rxDev = txDev
		txDev:wait()
	else
		txDev = device.config(txPort, rxMempool, 0, 1)
		rxDev = device.config(rxPort, rxMempool, 1, 0)
		device.waitForLinks()
	end
	dpdk.launchLua("timerSlave", txPort, rxPort, 0, 0, rate, size)
	dpdk.waitForSlaves()
end

function timerSlave(txPort, rxPort, txQueue, rxQueue, rate, size)
	local txDev = device.get(txPort)
	local rxDev = device.get(rxPort)
	local txQueue = txDev:getTxQueue(txQueue)
	local rxQueue = rxDev:getRxQueue(rxQueue)
	local mem = memory.createMemPool()
	local bufs = mem:bufArray(1)
	local rxBufs = mem:bufArray(128)
	local tsSent = 0
	local tsReceived = 0
	-- convert mpps rate into us inter-packet delay
	rate = 1 / rate
	printf("packet interval: %fus", rate)
	txQueue:enableTimestamps()
	rxQueue:enableTimestamps(1234)
	rxDev:filterTimestamps(rxQueue)
	local hist = histo:create()
	local startTime = dpdk.getTime()
	while dpdk.running() do
		bufs:fill(size)
		local pkt = bufs[1]:getUdpPacket()
		ts.fillPacket(bufs[1], 1234, size)
		pkt.eth.src:setString("90:e2:ba:2c:cb:02") -- klaipeda eth-test1 MAC
		pkt.eth.dst:setString("90:e2:ba:35:b5:81") -- tartu eth-test1 MAC
		pkt.ip.src:set(0xc0a80101) -- 192.168.1.1
		pkt.ip.dst:set(0xc0a80102) -- 192.168.1.2
		bufs:offloadUdpChecksums()
		-- sync clocks and send
		ts.syncClocks(txDev, rxDev)
		txQueue:send(bufs)
		-- increment the wait time when using large packets or slower links
		local tx = txQueue:getTimestamp(100)
		if tx then
			tsSent = tsSent + 1
			dpdk.sleepMicros(rate) -- rate limiting
			-- sent was successful, try to get the packet back (max. 100 us wait time before we assume the packet is lost)
			local rx = rxQueue:tryRecv(rxBufs, 100)
			if rx > 0 then
				tsReceived = tsReceived + 1
				local numPkts = 0
				for i = 1, rx do
					if bit.bor(rxBufs[i].ol_flags, dpdk.PKT_RX_IEEE1588_TMST) ~= 0 then
						numPkts = numPkts + 1
					end
				end
				local delay = (rxQueue:getTimestamp() - tx) * 6.4
				if numPkts == 1 then
					if delay > 0 and delay < 100000000 then
						hist:update(delay)
					end
				end -- else: got more than one packet, so we got a problem
				-- TODO: use sequence numbers in the packets to avoid bugs here
				rxBufs:freeAll()
			end
		end
	end
	for v, k in hist:samples() do
		printf("HistSample,delay=%f,count=%d", v.k, v.v)
	end
	local samples, sum, average = hist:totals()
	local lowerQuart, median, upperQuart = hist:quartiles()
	average = average or 0
	lowerQuart = lowerQuart or 0
	median = median or 0
	upperQuart = upperQuart or 0
	printf("HistStats,numSamples=%d,sum=%f,average=%f,lowerQuart=%f,median=%f,upperQuart=%f",samples,sum,average,lowerQuart,median,upperQuart)
	printf("TimestampSent,packets=%d",tsSent)
	printf("TimestampReceived,packets=%d",tsReceived)
	printf("TimestampPeriod,timespan=%d", dpdk.getTime()-startTime)
end

