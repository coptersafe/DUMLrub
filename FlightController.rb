#!/usr/bin/env ruby

require 'rubygems'
require 'colorize'
require 'json'
require 'jsonable'
$:.unshift File.expand_path('.',__dir__)
require 'DUML.rb'

class FlightController

    class Param
        attr_accessor :table, :item, :type, :length, :default, :value, :min, :max, :name, :packing

        @@packings = [ "C", "S<", "L<", "", "c", "s", "l<", "", "e" ]
        @@types = [ "uint8", "uint16", "uint32", "uint64", "int8", "int16", "int32", "int64", "float" ]

        def initialize(table, item, type, length, default, min, max, name)
            @table = table; @item = item; @type = type; @length = length
            @default = default; @value = default; @min = min; @max = max
            @name = name; @packing = @@packings[type]
        end

        def to_s
            out = "%d %4d  %-70s %-8s " % [ @table, @item, @name, @@types[@type] ]
            case type
            when 0..3
                out += " %12u %12u %12u %12u" % [ @min, @max, @default, @value ]
            when 4..7
                out += " %12d %12d %12d %12d" % [ @min, @max, @default, @value ]
            when 8
                out += " %12.4f %12.4f %12.4f %12.4f" % [ @min, @max, @default, @value ]
            end
            out
        end

        def to_json(a)
            { 'table' => @table, 'item' => @item, 'type' => @@types[@type], 'default' => @default,
              'value' => @value, 'min' => @min, 'max' => @max, 'name' => @name }.to_json
        end

        def self.from_json string
            data = JSON.load string
            self.new data['a'], data['b']
        end
    end

    def initialize(duml = nil, debug = false)
        @duml = duml
        @debug = debug
        @timeout = 0.2
        @src = @duml.src
        @dst = '0300'

        if debug
            # TODO: Add src & dst
            @duml.register_handler(0x00, 0x0e) do |msg| fc_status(msg); end
        end

        # See if we can reach the FC
        @versions = @duml.cmd_dev_ver_get(@src, @dst, @timeout)
        if @versions[:full] == nil
            raise "FlightController unresponsive"
        end
        puts "FC Version: %s" % @versions[:app]

        if fc_assistant_unlock() == nil
            raise "Couldn't do an 'assistant unlock'"
        end
    end

    def fc_status(msg)
        reply = msg.payload[1..-1].pack("C*")
        if reply.scan( /\[D-SEND DATA\]\[DEBUG\]\[Pub\]/ ) == []
            puts reply.yellow
        end
    end

    def fc_assistant_unlock()
        reply = @duml.send(DUML::Msg.new(@src, @dst, 0x40, 0x03, 0xdf, [ 0x00000001 ].pack("L<").unpack("C*")), @timeout)
        # TODO: parse reply
        return reply
    end

    def fc_ask_table(table)
        reply = @duml.send(DUML::Msg.new(@src, @dst, 0x40, 0x03, 0xe0,
                                         [ table ].pack("S<").unpack("C*")), @timeout)
        if reply == nil
            raise "No reply"
        end

        status = reply.payload[0..1].pack("C*").unpack("S<")[0]
        if status != 0
            return -status
        end

        table, unk, items = reply.payload[2..-1].pack("C*").unpack("S<L<S<");

        return items
    end

    def fc_ask_param(table, item)
        reply = @duml.send(DUML::Msg.new(@src, @dst, 0x40, 0x03, 0xe1,
                                         [ table, item ].pack("S<S<").unpack("C*")), @timeout)
        status = reply.payload[0..1].pack("C*").unpack("S<")[0]
        if status != 0
            return -status
        end

        table, item, type, length = reply.payload[2..9].pack("C*").unpack("S<S<S<S<")

        # uint8 = 0, uint16 = 1, uint32 = 2, int8 = 4, int16 = 5, int32 = 6, float = 8
        case type
        when 0..2
            default, min, max = reply.payload[10..21].pack("C*").unpack("L<L<L<")
        when 4..6
            default, min, max = reply.payload[10..21].pack("C*").unpack("l<l<l<")
        when 8
            default, min, max = reply.payload[10..21].pack("C*").unpack("eee")
        end

        name = reply.payload[22..-2].pack("C*")

        return Param.new(table, item, type, length, default, min, max, name)
    end

    def fc_get_param(param)
        reply = @duml.send(DUML::Msg.new(@src, @dst, 0x40, 0x03, 0xe2,
                                         [ param.table, 0x0001, param.item ].pack("S<S<S<").unpack("C*")), @timeout)
        status = reply.payload[0..1].pack("C*").unpack("S<")
        if status != 0
            return nil
        end

        #table, item  = reply.payload[2..5].pack("C*").unpack("S<S")
        param.value = reply.payload[6..-1].pack("C*").unpack(param.packing)
        return param
    end

    def fc_set_param(param, value = param.value)
        payload = [ param.table, 0x0001, param.item, value ].pack("S<S<S<%s" % param.packing).unpack("C*")
        reply = @duml.send(DUML::Msg.new(@src, @dst, 0x40, 0x03, 0xe3, payload), @timeout)
        status = reply.payload[0..1].pack("C*").unpack("S<")
        if status != 0
            return -status
        end
        return 0
    end
end

if __FILE__ == $0
    # debugging

    port = $*[0]
    if port == nil
        puts "Usage: FlightController.rb <serial port>"
        exit
    end

    con = DUML::ConnectionSerial.new(port)
    duml = DUML.new(0x2a, 0xc3, con, 0.5, false)
    fc = FlightController.new(duml, false)

    all = []
    [0, 1].each do |t|
        items = fc.fc_ask_table(t)
        puts "Table %d => %d items" % [t, items]
        (0..(items - 1)).each do |i|
            p = fc.fc_ask_param(t, i)
            fc.fc_get_param(p)
            all = all + [ p ]
            #puts "%d %d" % [ p.table, p.item ]
            #puts p.to_json
        end
    end
    puts JSON.pretty_generate(all)
end

# vim: expandtab:ts=4:sw=4
