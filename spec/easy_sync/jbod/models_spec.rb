# frozen_string_literal: true

RSpec.describe EasySync::Jbod::Drive do
  def drive(model)
    described_class.new(serial_number: 'SN1', friendly_name: 'backup-01-8tb', capacity_bytes: 8 * TB, model: model)
  end

  describe '#manufacturer' do
    it 'recognises Seagate models by their ST-number convention, with no separate brand token to find' do
      expect(drive('ST8000VN004-2M2101').manufacturer).to eq('Seagate')
      expect(drive('ST2000LM015-2E8174').manufacturer).to eq('Seagate')
    end

    it 'recognises other makers from the token smartctl already puts in Device Model' do
      expect(drive('WDC WD80EFZZ-68BTXN0').manufacturer).to eq('Western Digital')
      expect(drive('TOSHIBA HDWE160').manufacturer).to eq('Toshiba')
      expect(drive('APPLE SSD AP2048Z').manufacturer).to eq('Apple')
      expect(drive('HGST HUH721212ALE600').manufacturer).to eq('HGST')
    end

    it 'is case-insensitive' do
      expect(drive('toshiba hdwe160').manufacturer).to eq('Toshiba')
    end

    it 'returns nil for an unrecognised model, or no model at all' do
      expect(drive('Some Weird Drive XYZ').manufacturer).to be_nil
      expect(drive(nil).manufacturer).to be_nil
    end
  end

  describe '#branded_model' do
    it 'prepends the brand for Seagate, whose model numbers carry no brand text' do
      expect(drive('ST8000VN004-2M2101').branded_model).to eq('Seagate ST8000VN004-2M2101')
    end

    it "replaces the raw token with the brand's full name, without duplicating it" do
      expect(drive('WDC WD80EFZZ-68BTXN0').branded_model).to eq('Western Digital WD80EFZZ-68BTXN0')
      expect(drive('TOSHIBA HDWE160').branded_model).to eq('Toshiba HDWE160')
    end

    it 'falls back to the raw model string when the maker is unrecognised' do
      expect(drive('Some Weird Drive XYZ').branded_model).to eq('Some Weird Drive XYZ')
    end

    it 'is nil when there is no model at all' do
      expect(drive(nil).branded_model).to be_nil
    end
  end
end
