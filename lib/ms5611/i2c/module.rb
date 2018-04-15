# http://www.te.com/commerce/DocumentDelivery/DDEController?Action=showdoc&DocId=Data+Sheet%7FMS5611-01BA03%7FB%7Fpdf%7FEnglish%7FENG_DS_MS5611-01BA03_B.pdf%7FCAT-BLPS0036
module Ms5611
  module I2c
    class Module

      class I2CNotFoundError < StandardError; end

      class << self
        def detect_i2c_bus_path
          found = `i2cdetect -l`.split("\t").find{|l| l.start_with? "i2c-"}
          raise I2CNotFoundError.new("make sure i2c is enabled") unless found

          "/dev/#{found}"
        end

        def print_i2c_addresses
          bus_number = detect_i2c_bus_path.split("-").last
          system("i2cdetect -y #{bus_number}")
        end
      end

      # command sequence
      # https://i.gyazo.com/487b275aad602cdca81055026af9ce3a.png
      def initialize(i2c_device_address:, i2c_bus_path: self.class::detect_i2c_bus_path)
        @i2c_address = i2c_device_address
        @i2c_device = I2C.create(i2c_bus_path)

        reset
        # https://i.gyazo.com/bee6120d66dbdbd812c652c2b4770cf1.png
        @proms = 1.upto(6).collect do |address|
          read_prom(address)
        end
        @crc4 = read_crc4
      end

      # https://i.gyazo.com/17fb7cdc7306ebec31e64a51659869fb.png
      # ex 2007 = 20.07 °C
      def temperature
        raw_temp_value = temp
        (raw_temp_value - t2(raw_temp_value)) / 100.0
      end

      # https://i.gyazo.com/17fb7cdc7306ebec31e64a51659869fb.png
      # Temperature compensated pressure (10…1200mbar with 0.01mbar resolution)
      # P = (D1 * SENS / 2**21 - OFF) / 2**15
      def pressure
        raw_temp_value = temp

        new_off = off - off2(raw_temp_value)
        new_sens = sens - sens2(raw_temp_value)
        p = (d1 * new_sens / 2**21 - new_off) / 2**15
        p / 100.0
      end

      private

        attr_reader :i2c_device, :i2c_address, :proms, :crc4
        BITS_IN_BYTE = 8
        # https://i.gyazo.com/c7e6043ff8d8c366dbce3f3def0b7d25.png
        RESET_SLEEP_TIME = 2.8.ceil / 1000.0
        # https://i.gyazo.com/dc1977aec03252d7dcaf91da63b2093d.png
        CONVERSION_SLEEP_TIME = 8.22.ceil / 1000.0

        # commands
        # https://i.gyazo.com/c5705fd105799aff9297524744cf5d41.png
        def write(*params)
          i2c_device.write i2c_address, *params
        end

        def read(reading_bytes, *params)
          i2c_device.read(i2c_address, reading_bytes, *params).bytes
        end

        # Reset 0 0 0 1 1 1 1 0 0x1E
        def reset
          write 0x1E
          sleep RESET_SLEEP_TIME
        end

        # https://i.gyazo.com/bee6120d66dbdbd812c652c2b4770cf1.png
        # PROM Read 1 0 1 0 Ad2 Ad1 Ad0 0 0xA0 to 0xAE
        # C1 Pressure sensitivity | SENST1 unsigned int 16 16
        def read_prom(address_1_to_6)
          byte_size = 16 / BITS_IN_BYTE
          ad2_1_0 = address_1_to_6.to_s(2).to_s.rjust(3, "0")

          b1, b0 = read(byte_size, "1010#{ad2_1_0}0".to_i(2))
          b1 <<= 8
          b1 + b0
        end

        # https://i.gyazo.com/bee6120d66dbdbd812c652c2b4770cf1.png
        # PROM Read 1 0 1 0 Ad2 Ad1 Ad0 0 0xA0 to 0xAE
        # 7th address 0xAE
        def read_crc4
          byte_size = 16 / BITS_IN_BYTE
          _, b0 = read(byte_size, 0xAE)
          b0 &= 0b00001111
        end

        # https://i.gyazo.com/4b676da17ee1ed37c7e16c114eb0fa48.png
        6.times do |address|
          define_method("c#{address + 1}") do
            # 0 - 5 index  => address 1 - 6
            proms[address]
          end
        end

        # https://i.gyazo.com/4bb84442d60e5378c593f677ba148d90.png
        # Convert D1 (OSR=4096) 0 1 0 0 1 0 0 0 0x48
        # Convert D2 (OSR=4096) 0 1 0 1 1 0 0 0 0x58
        # send 0 0 0 0 0 0 0 0 to read
        [0x48, 0x58].each.with_index(1) do |command, index|
          define_method "d#{index}" do
            write(command)
            sleep CONVERSION_SLEEP_TIME

            byte_size = 24 / BITS_IN_BYTE
            b2, b1, b0 = read(byte_size, 0x00)
            b2 <<= 16
            b1 <<= 8
            b2 + b1 + b0
          end
        end

        # Difference between actual and reference temperature [2]
        # dT = D2 - C5 * 2**8
        def dt
          d2 - (c5 * 2**8)
        end

        # Actual temperature (-40…85°C with 0.01°C resolution)
        # TEMP = 2000 + dT * C6 / 2**23
        def temp
          2000 + (dt * c6 / 2**23)
        end

        # Offset at actual temperature [3]
        # OFF = C2 * 2**16 + (C4 * dT ) / 2**7
        def off
          c2 * 2**16 + (c4 + dt) / 2**7
        end

        # Sensitivity at actual temperature [4]
        # SENS = C1 * 2**15.0 + (C3 * dT )/ 2**8.0
        def sens
          c1 * 2**15 + (c3 * dt ) / 2**8
        end

        def if_below_20(raw_temp_value)
          return 0 unless raw_temp_value < 2000
          yield
        end

        def if_15_below_zero(raw_temp_value, value)
          return value unless raw_temp_value < -1500
          yield value
        end

        def t2(raw_temp_value)
          if_below_20(raw_temp_value) do
            dt**2 / 2**31
          end
        end

        def off2(raw_temp_value)
          if_below_20(raw_temp_value) do
            value = 5 * (raw_temp_value - 2000)**2 / 2
            if_15_below_zero(raw_temp_value, value) do |off2|
              off2 + 7 * (raw_temp_value + 1500)**2
            end
          end
        end

        def sens2(raw_temp_value)
          if_below_20(raw_temp_value) do
            value = 5 * (raw_temp_value - 2000)**2 / 2**2
            if_15_below_zero(raw_temp_value, value) do |sens2|
              sens2 + 11 * (raw_temp_value + 1500)**2 / 2
            end
          end
        end

    end

  end
end