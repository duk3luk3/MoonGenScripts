local dpdk	= require "dpdk"
local memory	= require "memory"
local device	= require "device"
local ts	= require "timestamping"
local dpdkc	= require "dpdkc"
local filter	= require "filter"
local histo	= require "histogram"
local ffi	= require "ffi"

function master(...)
	local txPort, rxPort, rate = tonumberall(...)
	if not txPort or not rxPort then
		errorf("usage: txPort rxPort [rate]")
	end
	rate = rate or 10000
	local rcWorkaround = rate > (64 * 64) / (84 * 84) * 10000 and rate < 10000
	local rxMempool = memory.createMemPool()
	local txDev, rxDev
	if txPort == rxPort then
		txDev = device.config(txPort, rxMempool, 2, rcWorkaround and 4 or 2)
		rxDev = txDev
		txDev:wait()
	else
		txDev = device.config(txPort, rxMempool, 1, rcWorkaround and 4 or 2)
		rxDev = device.config(rxPort, rxMempool, 2, 1)
		device.waitForDevs(txDev, rxDev)
	end
	if rcWorkaround then
		txDev:getTxQueue(0):setRate(rate / 3)
		txDev:getTxQueue(2):setRate(rate / 3)
		txDev:getTxQueue(3):setRate(rate / 3)
	else
		txDev:getTxQueue(0):setRate(rate)
	end
	dpdk.launchLua("timerSlave", txPort, rxPort, 1, 1)
	dpdk.launchLua("loadSlave", txPort, 0)
	dpdk.launchLua("counterSlave", rxPort, 0)
	if rcWorkaround then
		dpdk.launchLua("loadSlave", txPort, 2)
		dpdk.launchLua("loadSlave", txPort, 3)
	end
	dpdk.waitForSlaves()
end

function loadSlave(port, queue)
	local queue = device.get(port):getTxQueue(queue)
	local mem = memory.createMemPool(function(buf)
		local data = ffi.cast("uint8_t*", buf.pkt.data)
		-- src/dst mac
		for i = 0, 10 do
			data[i] = i
		end
		data[11] = math.random(16)
		-- eth type
		data[12] = 0x12
		data[13] = 0x34
	end)
	local MAX_BURST_SIZE = 31
	local startTime = dpdk.getTime()
	local lastPrint = startTime
	local totalSent = 0
	local lastTotal = 0
	local lastSent = 0
	local bufs = mem:bufArray(MAX_BURST_SIZE)
	while dpdk.running() do
		bufs:alloc(60)
		totalSent = totalSent + queue:send(bufs)
		local time = dpdk.getTime()
		if time - lastPrint > 1 then
			local mpps = (totalSent - lastTotal) / (time - lastPrint) / 10^6
			printf("Sent,packets=%d,rate=%f", totalSent, mpps)
			lastTotal = totalSent
			lastPrint = time
		end
	end
	local time = dpdk.getTime()
	local mpps = (totalSent) / (time - startTime) / 10^6
	printf("TotalSent,packets=%d,rate=%f", totalSent, mpps)
end

function counterSlave(port)
	local dev = device.get(port)
	dev:l2Filter(0x1234, filter.DROP)
	local total = 0
	while dpdk.running() do
		local time = dpdk.getTime()
		dpdk.sleepMillis(1000)
		local elapsed = dpdk.getTime() - time
		local pkts = dev:getRxStats(port)
		total = total + pkts
		printf("Received,packets=%d,rate=%f", total, pkts / elapsed / 10^6)
	end
	printf("TotalReceived,packets=%d", total)
end

function timerSlave(txPort, rxPort, txQueue, rxQueue)
	local txDev = device.get(txPort)
	local rxDev = device.get(rxPort)
	local txQueue = txDev:getTxQueue(txQueue)
	local rxQueue = rxDev:getRxQueue(rxQueue)
	local mem = memory.createMemPool()
	local buf = mem:bufArray(1)
	local rxBufs = mem:bufArray(2)
	txQueue:enableTimestamps()
	rxQueue:enableTimestamps()
	local hist = histo:create()
	dpdk.sleepMillis(4000)
	local ptpseq = 0
	local timestamps = {}
	while dpdk.running() do
		ptpseq = (ptpseq + 1) % 1000000
		buf:alloc(60)
		ts.fillL2Packet(buf[1], ptpseq)
		-- sync clocks and send
		--ts.syncClocks(txDev, rxDev)
		txQueue:send(buf)
		-- increment the wait time when using large packets or slower links
		local tx = txQueue:getTimestamp(100)
		if tx then
			timestamps[ptpseq] = tx
			dpdk.sleepMicros(500) -- minimum latency to limit the packet rate
			-- sent was successful, try to get the packet back (max. 10 ms wait time before we assume the packet is lost)
			local rx = rxQueue:tryRecv(rxBufs, 10000)
			if rx > 0 then
				local nummatched = 0
				local tsi = 0
				for i = 1, rx do
					if bit.bor(rxBufs[i].ol_flags, dpdk.PKT_RX_IEEE1588_TMST) ~= 0 then
						nummatched = nummatched + 1
						tsi = i
					end
				end
				local seq = ts.readSeq(rxBufs[tsi])
				if timestamps[seq] then
					local delay = (rxQueue:getTimestamp() - timestamps[seq]) * 6.4
					timestamps[seq] = nil
					if nummatched == 1 and delay > 0 and delay < 100000000 then
						hist:update(delay)
					end
				end
				rxBufs:freeAll()
			end
		end
	end
	for v, k in hist:samples() do
		printf("HistSample,delay=%f,count=%d", v.k, v.v)
	end
	local samples, sum, average = hist:totals()
	local lowerQuart, median, upperQuart = hist:quartiles()
	printf("HistStats,numSamples=%d,sum=%f,average=%f,lowerQuart=%f,median=%f,upperQuart=%f",samples,sum,average,lowerQuart,median,upperQuart)
	io.stdout:flush()
end

