local dpdk		= require "dpdk"
local memory	= require "memory"
local ts		= require "timestamping"
local device	= require "device"
local filter	= require "filter"
local histo		= require "histogram"

function master(...)
	local txPort, rxPort, rate = tonumberall(...)
	if not txPort or not rxPort then
		errorf("usage: txPort rxPort [rate (Mpps)]")
	end
	rate = rate or 2
	local txDev = device.config(txPort, 2, 2)
	local rxDev = device.config(rxPort, 2, 2)
	device.waitFor(txDev, rxDev)
	dpdk.launchLua("loadSlave", txDev, rxDev, txDev:getTxQueue(0), rate, 60)
	dpdk.launchLua("timerSlave", txDev, rxDev, txDev:getTxQueue(1), rxDev:getRxQueue(1), 60)
	dpdk.waitForSlaves()
end

function loadSlave(dev, rxDev, queue, rate, size)
	local mem = memory.createMemPool(function(buf)
		buf:getEthernetPacket():fill{
			ethType = 0x1234
		}
	end)
	rxDev:l2Filter(0x1234, filter.DROP)
	local lastPrint = dpdk.getTime()
	local totalSent = 0
	local lastTotal = 0
	local lastSent = 0
	local totalReceived = 0
	local bufs = mem:bufArray(31)
	while dpdk.running() do
		bufs:fill(size)
		for _, buf in ipairs(bufs) do
			-- this script uses Mpps instead of Mbit (like the other scripts)
			buf:setDelay(poissonDelay(10^10 / 8 / (rate * 10^6) - size - 24))
		end
		totalSent = totalSent + queue:sendWithDelay(bufs)
		local time = dpdk.getTime()
		if time - lastPrint > 1 then
			local rx = rxDev:getRxStats()
			totalReceived = totalReceived + rx
			local mpps = (totalSent - lastTotal) / (time - lastPrint) / 10^6
			printf("Sent,packets=%d,rate=%f", totalSent, mpps)
			printf("Received %d packets, current rate %.2f Mpps", totalReceived, rx / (time - lastPrint) / 10^6)
			printf("Received,packets=%d,rate=%f", totalReceived, rx / (time-lastPrint) / 10^6)
			lastTotal = totalSent
			lastPrint = time
		end
	end
	local time = dpdk.getTime()
	local mbits = (totalSent) / (time - startTime) / 10^6
	printf("TotalSent,packets=%d,rate=%f", totalSent, mbits)
	printf("TotalReceived,packets=%d", totalReceived)
end

function timerSlave(txDev, rxDev, txQueue, rxQueue)
	local mem = memory.createMemPool()
	local buf = mem:bufArray(1)
	local rxBufs = mem:bufArray(2)
	txQueue:enableTimestamps()
	rxQueue:enableTimestamps()
	local hist = histo:create()
	dpdk.sleepMillis(4000)
	local ptpseq = 0
	while dpdk.running() do
		ptpseq = (ptpseq + 1) % 1000000
		buf:fill(60)
		ts.fillL2Packet(buf[1], ptpseq)
		-- sync clocks and send
		ts.syncClocks(txDev, rxDev)
		txQueue:send(buf)
		-- increment the wait time when using large packets or slower links
		local tx = txQueue:getTimestamp(100)
		if tx then
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

