# frozen_string_literal: true

# Builds a fake Backblaze Personal data dir at Backblaze::DATA_DIR (which
# spec_helper points into the temp dir), in the format the real one uses.
module BackblazeHelpers
  # +volumes+: { mount_point => { files:, bytes:, scanned_at: Time or nil } }
  def fake_backblaze(volumes, completed_at: Time.utc(2026, 9, 26, 15, 8))
    dir = EasySync::Jbod::Backblaze::DATA_DIR
    guids = volumes.keys.each_with_index.to_h { |mount, i| [mount, format('v%03dfake', i)] }
    write_file(File.join(dir, 'bzvolumes.xml'), <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <contents>
      #{guids.map { |mount, g| %(<bzvolume bzVolumeGuid="#{g}" mountPointPathHex="#{"#{mount}/".unpack1('H*')}" typeOfVolumeTwoCharCode="gm" />) }.join("\n")}
      </contents>
    XML
    write_file(File.join(dir, 'bzreports', 'bzstat_remainingbackup.xml'), <<~XML)
      <contents>
      #{volumes.map { |mount, v| %(<bzvolume bzVolumeGuid="#{guids[mount]}" pervol_remaining_files_numfiles="#{v[:files]}" pervol_remaining_files_numbytes="#{v[:bytes]}" />) }.join("\n")}
      </contents>
    XML
    write_file(File.join(dir, 'bzreports', 'bzstat_lastbackupcompleted.xml'),
               %(<contents>\n<lastbackupcompleted gmt_millis="#{(completed_at.to_f * 1000).to_i}" />\n</contents>\n))
    volumes.each do |mount, v|
      next unless v[:scanned_at]

      list = write_file(File.join(dir, 'bzfilelists', "#{guids[mount]}______filelist.dat"), 'x')
      File.utime(v[:scanned_at], v[:scanned_at], list)
    end
    dir
  end
end

RSpec.configure { |c| c.include BackblazeHelpers }
