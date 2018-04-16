require "spec_helper"

module Ms5611
  module I2c
    RSpec.describe Module do
      let(:i2c_device){ spy :i2c_device }

      before do
        allow(I2C).to receive(:create).and_return i2c_device
      end

      describe :class do
        describe :detect_i2c_bus_path do
          before do
            allow(Module).to receive(:`).and_return list_text
          end

          context "i2c not found" do
            let(:list_text){ "" }
            it{ expect{|block| Module.detect_i2c_bus_path &block }.to raise_error(Module::I2CNotFoundError) }
          end

          context "i2c found" do
            let(:list_text){ "i2c-1" }
            it{ expect(Module.detect_i2c_bus_path).to eq "/dev/i2c-1" }
          end
        end

        describe :print_i2c_addresses do
          before do
            allow(Module).to receive(:`)
            allow(Module).to receive(:detect_i2c_bus_path).and_return("/dev/i2c-1")
          end

          it do
            allow(Module).to receive(:system)
            Module.print_i2c_addresses
            expect(Module).to have_received(:system).with("i2cdetect -y 1")
          end
        end
      end

      describe :private do
        let(:i2c_address){ 0x77 }

        before do
        end

        subject do
          allow_any_instance_of(Module).to receive(:load_proms)
          Module.new(i2c_device_address: i2c_address, i2c_bus_path: "/dev/i2c-1").tap do |s|
            allow(s).to receive(:i2c_address).and_return i2c_address
            allow(s).to receive(:sleep)
          end
        end

        describe :write do
          it do
            subject.send(:write, 0x00)
            expect(i2c_device).to have_received(:write).with(i2c_address, 0x00)
          end
        end

        describe :read do
          it do
            subject.send(:read, 1, 0x00)
            expect(i2c_device).to have_received(:read).with(i2c_address, 1, 0x00)
          end
        end

        describe :reset do
          it do
            subject.send(:reset)
            expect(i2c_device).to have_received(:write).with(i2c_address, 0x1E)
            expect(subject).to have_received(:sleep).with(Module::RESET_SLEEP_TIME)
          end
        end

        describe :read_prom do
          it do
            expect(subject).to receive(:read).with(2, 0b10100010).and_return [1, 2]
            expect(subject.send(:read_prom, 1)).to eq(256 + 2)
          end
        end

        describe :read_crc4 do
          it do
            expect(subject).to receive(:read).with(2, 0b10101110).and_return [1, 2]
            expect(subject.send(:read_crc4)).to eq 2 # first byte is ignored
          end
        end

        describe :check_crc4 do
          before do
            allow(subject).to receive(:read_prom).with(0).and_return 2136
            allow(subject).to receive(:proms).and_return [46954, 50001, 28678, 25683, 32024, 27516]
            allow(subject).to receive(:read_prom).with(7).and_return 46082
          end

          it{ expect(subject.send :check_crc4).to eq 2 }
        end

        describe :load_proms do
          subject{ Module.new(i2c_device_address: i2c_address, i2c_bus_path: "/dev/i2c-1") }

          context "when fails to match crc4" do
            before do
              allow_any_instance_of(Module).to receive(:reset)
              allow_any_instance_of(Module).to receive(:read_prom)

              allow_any_instance_of(Module).to receive(:read_crc4).and_return(1)
              allow_any_instance_of(Module).to receive(:check_crc4).and_return(0)
            end

            it{ expect{ subject }.to raise_error Module::Crc4Error }
          end

          context "when crc4 matches" do
            before do
              allow_any_instance_of(Module).to receive(:reset)
              allow_any_instance_of(Module).to receive(:read_prom)

              allow_any_instance_of(Module).to receive(:read_crc4).and_return(1)
              allow_any_instance_of(Module).to receive(:check_crc4).and_return(1)
            end

            it do
              expect{ subject }.not_to raise_error
              expect(subject).to have_received(:reset).once
              expect(subject).to have_received(:read_prom).exactly(6).times
            end
          end
        end

        describe "c1 to c6" do
          let(:proms){ (1..6).to_a }

          before do
            allow(subject).to receive(:proms).and_return proms
          end

          describe :c1 do
            it{ expect(subject.send :c1).to eq 1 }
          end

          describe :c2 do
            it{ expect(subject.send :c2).to eq 2 }
          end

          describe :c3 do
            it{ expect(subject.send :c3).to eq 3 }
          end

          describe :c4 do
            it{ expect(subject.send :c4).to eq 4 }
          end

          describe :c5 do
            it{ expect(subject.send :c5).to eq 5 }
          end

          describe :c6 do
            it{ expect(subject.send :c6).to eq 6 }
          end
        end

        describe :d1 do
          it do
            expect(subject).to receive(:write).with(0x48)
            expect(subject).to receive(:sleep).with(Module::CONVERSION_SLEEP_TIME)
            expect(subject).to receive(:read).with(3, 0x00).and_return([1, 2, 3])
            expect(subject.send :d1).to eq(65536 + 512 + 3)
          end
        end

        describe :d2 do
          it do
            expect(subject).to receive(:write).with(0x58)
            expect(subject).to receive(:sleep).with(Module::CONVERSION_SLEEP_TIME)
            expect(subject).to receive(:read).with(3, 0x00).and_return([1, 2, 3])
            expect(subject.send :d2).to eq(65536 + 512 + 3)
          end
        end

        describe :dt do
          before do
            allow(subject).to receive(:d2).and_return 1
            allow(subject).to receive(:c5).and_return 2
          end

          it{ expect(subject.send :dt).to eq(1 - (2 << 8)) }
        end

        describe :temp do
          before do
            allow(subject).to receive(:dt).and_return 1
            allow(subject).to receive(:c6).and_return 2
          end

          it{ expect(subject.send :temp).to eq(2000 + (1 * 2 >> 23)) }
        end

        describe :off do
          before do
            allow(subject).to receive(:c2).and_return 1
            allow(subject).to receive(:c4).and_return 2
            allow(subject).to receive(:dt).and_return 3
          end

          it{ expect(subject.send :off).to eq((1 << 16) + ((2 + 3) >> 7)) }
        end

        describe :sens do
          before do
            allow(subject).to receive(:c1).and_return 1
            allow(subject).to receive(:c3).and_return 2
            allow(subject).to receive(:dt).and_return 3
          end

          it{ expect(subject.send :sens).to eq((1<<15) + ((2 * 3 )>>8)) }
        end

        describe :if_below_20 do
          context "20 and above" do
            let(:raw_temp_value){ 2000 }

            it do
              expect{|block| subject.send(:if_below_20, raw_temp_value, &block) }.
                not_to yield_control

              expect(subject.send :if_below_20, raw_temp_value).to be_zero
            end
          end

          context "below 20" do
            let(:raw_temp_value){ 1999 }

            it do
              expect{|block| subject.send(:if_below_20, raw_temp_value, &block) }.
                to yield_control
            end
          end
        end

        describe :if_15_below_zero do
          let(:value){ 100 }

          context "-15 and above" do
            let(:raw_temp_value){ -1500 }
            it do
              expect{|block| subject.send(:if_15_below_zero, raw_temp_value, value, &block) }.
                not_to yield_control

              expect(subject.send :if_15_below_zero, raw_temp_value, value).to eq value
            end
          end

          context "below -15" do
            let(:raw_temp_value){ -1501 }
            it do
              expect{|block| subject.send(:if_15_below_zero, raw_temp_value, value, &block) }.
              to yield_control
            end
          end
        end

        describe :t2 do
          context "20 and above" do
            let(:raw_temp_value){ 2000 }
            it{ expect(subject.send :t2, raw_temp_value).to be_zero }
          end

          context "below 20" do
            before do
              allow(subject).to receive(:dt).and_return 100
            end

            let(:raw_temp_value){ 1999 }
            it{ expect(subject.send :t2, raw_temp_value).to eq((100**2)>>31) }
          end
        end

        describe :off2 do
          context "20 and above" do
            let(:raw_temp_value){ 2000 }
            it{ expect(subject.send :off2, raw_temp_value).to be_zero }
          end

          context "below 20" do
            let(:raw_temp_value){ 1999 }
            it{ expect(subject.send :off2, raw_temp_value).to eq(5 * (raw_temp_value - 2000)**2 / 2) }
          end

          context "below -15" do
            let(:raw_temp_value){ -1501 }
            let(:first_off2){ 5 * (raw_temp_value - 2000)**2 / 2 }
            it{ expect(subject.send :off2, raw_temp_value).to eq(first_off2 + 7 * (raw_temp_value + 1500)**2) }
          end
        end

        describe :sens2 do
          context "20 and above" do
            let(:raw_temp_value){ 2000 }
            it{ expect(subject.send :sens2, raw_temp_value).to be_zero }
          end

          context "below 20" do
            let(:raw_temp_value){ 1999 }
            it{ expect(subject.send :sens2, raw_temp_value).to eq(5 * (raw_temp_value - 2000)**2 / 2**2) }
          end

          context "below -15" do
            let(:raw_temp_value){ -1501 }
            let(:first_sens2){ 5 * (raw_temp_value - 2000)**2 / 2**2 }
            it{ expect(subject.send :sens2, raw_temp_value).to eq(first_sens2 + 11 * (raw_temp_value + 1500)**2 / 2) }
          end
        end

      end
    end
  end
end
