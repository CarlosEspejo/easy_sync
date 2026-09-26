# frozen_string_literal: true

# Regenerates the README's dashboard screenshots (docs/images/dashboard-*.png)
# from a made-up manifest, so the public repo never shows a real library.
# Run it after changing the dashboard's look:
#
#     bundle exec ruby script/dashboard_screenshot.rb
#
# Needs Google Chrome (headless) and macOS's `sips`. It writes only a temp
# dir and docs/images/; ~/.easy_sync is never read or touched.
require_relative '../lib/easy_sync'
require 'fileutils'
require 'tmpdir'

CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
IMAGES = File.expand_path('../docs/images', __dir__)
TB = 1000**4
GB = 1000**3
NOW = Time.utc(2026, 9, 25, 9, 30)
FixedClock = Struct.new(:now)

def iso(time) = time.utc.iso8601

# name, TB, SMART status, power-on hours, reallocated sectors, connected,
# how full to make it (JBOD drives run nearly full), days since its scrub.
DRIVES = [
  ['backup-01-8tb', 8, 'ok', 21_400, 0, true, 0.91, 3],
  ['backup-02-6tb', 6, 'degraded_stable', 48_900, 24, true, 0.96, 5],
  ['backup-03-8tb', 8, 'ok', 30_100, 0, true, 0.84, 9],
  ['backup-04-8tb', 8, 'ok', 12_700, 0, true, 0.88, 12],
  ['backup-05-3tb', 3, 'ok', 61_200, 0, true, 0.93, 41],
  ['backup-06-8tb', 8, 'ok', 9_800, 0, true, 0.72, 2],
  ['backup-07-6tb', 6, 'ok', 26_300, 0, true, 0.79, 7],
  ['backup-08-2tb', 2, 'unknown', nil, nil, false, 0.64, nil]
].freeze

# Public-domain films and generic names; nothing from a real library.
MOVIES = ['Metropolis', 'Nosferatu', 'The General', 'Sherlock Jr.', 'Safety Last!', 'The Kid', 'Modern Times',
          'Night of the Living Dead', 'His Girl Friday', 'Charade', 'Detour', 'The Little Shop of Horrors',
          'Carnival of Souls', 'Plan 9', 'The Phantom of the Opera'].freeze

# [folder_path, relative weight, drive, scope]; weights are scaled so each
# drive ends up as full as DRIVES says.
def demo_folders
  folders = []
  MOVIES.each_with_index { |t, i| folders << ["movies/#{t} (#{1920 + i * 3})", 8 + i % 5, 'backup-01-8tb'] }
  (1..40).each { |i| folders << [format('tv/Show %02d', i), 60 + i * 7, i <= 22 ? 'backup-03-8tb' : 'backup-04-8tb'] }
  (2012..2025).each { |y| folders << ["photos/#{y}", 40 + (y - 2012) * 9, 'backup-02-6tb'] }
  ['Home Videos', 'Scans', 'Music', 'Projects'].each_with_index do |n, i|
    folders << ["archive/#{n}", 300 + i * 150, 'backup-06-8tb']
  end
  folders << ['archive', 2, 'backup-06-8tb', 'root']
  (1..30).each { |i| folders << [format('music/Artist %02d', i), 4 + i, i <= 18 ? 'backup-07-6tb' : 'backup-05-3tb'] }
  (1..6).each { |i| folders << [format('archive/Old Backups %d', i), 90, 'backup-08-2tb'] }
  folders
end

def build_manifest(path)
  m = EasySync::Jbod::Manifest.new(SQLite3::Database.new(path), clock: FixedClock.new(NOW))
  serials = {}
  DRIVES.each_with_index do |(name, tb, status, hours, realloc), i|
    serial = format('DEMO%04dSN', 1000 + i)
    serials[name] = serial
    m.register_drive(serial_number: serial, friendly_name: name, capacity_bytes: tb * TB,
                     model: tb >= 6 ? 'WDC WD80EFZZ-68BTXN0' : 'ST3000DM007-1WY10G', added_date: '2026-09-10T00:00:00Z')
    if status == 'unknown'
      m.update_drive_health(serial, status: status, checked_at: '2026-09-15T20:00:00Z',
                                    detail: 'SMART not exposed by this enclosure (smartctl and diskutil both blind)')
    else
      m.record_smart_check(serial, reallocated_sector_ct: realloc, checked_at: '2026-09-12T00:00:00Z')
      m.record_smart_check(serial, reallocated_sector_ct: realloc, checked_at: iso(NOW - 3600))
      detail = realloc.positive? ? "PASSED · Reallocated_Sector_Ct #{realloc}" : 'PASSED'
      m.update_drive_health(serial, status: status, detail: detail, power_on_hours: hours, checked_at: iso(NOW - 3600))
    end
  end
  [m, serials]
end

def sized(folders)
  spec = DRIVES.to_h { |d| [d[0], d] }
  weights = Hash.new(0)
  folders.each { |(_, w, drive)| weights[drive] += w }
  folders.map do |(path, w, drive, scope)|
    _, tb, *, fill, _ = spec[drive]
    [path, (w * fill * (tb * TB - 40 * GB) / weights[drive]).round, drive, scope || 'tree']
  end
end

# A made-up Backblaze install (never the real one): every drive scanned after
# the demo sync and uploaded, except backup-07-6tb, still uploading.
def fake_backblaze(dir)
  bz = File.join(dir, 'backblaze')
  FileUtils.mkdir_p([File.join(bz, 'bzreports'), File.join(bz, 'bzfilelists')])
  guids = DRIVES.each_with_index.to_h { |d, i| [d[0], format('vdemo%03d', i)] }
  volumes = guids.map { |name, g| %(<bzvolume bzVolumeGuid="#{g}" mountPointPathHex="#{"/Volumes/#{name}/".unpack1('H*')}" />) }
  remaining = guids.map do |name, g|
    files, bytes = name == 'backup-07-6tb' ? [1204, 38 * GB] : [0, 0]
    %(<bzvolume bzVolumeGuid="#{g}" pervol_remaining_files_numfiles="#{files}" pervol_remaining_files_numbytes="#{bytes}" />)
  end
  File.write(File.join(bz, 'bzvolumes.xml'), "<contents>\n#{volumes.join("\n")}\n</contents>\n")
  File.write(File.join(bz, 'bzreports', 'bzstat_remainingbackup.xml'), "<contents>\n#{remaining.join("\n")}\n</contents>\n")
  guids.each_value do |g|
    list = File.join(bz, 'bzfilelists', "#{g}______filelist.dat")
    File.write(list, '')
    File.utime(NOW - 1800, NOW - 1800, list)
  end
  bz
end

def render(dir)
  m, serials = build_manifest(File.join(dir, 'manifest.sqlite3'))
  folders = sized(demo_folders)
  run_start = NOW - 5400
  folders.each_with_index do |(path, size, drive, scope), i|
    m.assign_folder(path, serials[drive], size_bytes: size, scope: scope, at: '2026-09-12T02:00:00Z')
    next if drive == 'backup-08-2tb'

    started = run_start + i * 20
    m.record_sync(folder_path: path, drive_serial: serials[drive], started_at: iso(started),
                  finished_at: iso(started + 15), exit_status: 0, bytes_transferred: (i % 9).zero? ? 3 * GB : 20_000,
                  total_size_bytes: size, run_started_at: iso(run_start))
  end

  inventory = folders.map { |(path, size, drive)| { folder_path: path, size_bytes: size, state: 'placed', detail: "on #{drive}" } }
  inventory << { folder_path: 'tv/Show 41', size_bytes: 2600 * GB, state: 'unplaced', detail: 'no drive has room' }
  inventory << { folder_path: 'tv/Show 42', size_bytes: 1900 * GB, state: 'unplaced', detail: 'no drive has room' }
  m.replace_source_inventory(inventory, at: iso(run_start + 60))

  scrub_days = DRIVES.to_h { |d| [d[0], d[7]] }
  folders.each do |(path, _, drive)|
    days = scrub_days[drive] or next
    m.reconcile_checksums(serials[drive], path, { 'a.bin' => [1, 1] })
    m.checksum_hashed(serials[drive], path, 'a.bin', outcome: :baseline, digest: 'x', at: iso(NOW - days * 86_400))
  end

  used = Hash.new(40 * GB)
  folders.each { |(_, size, drive)| used[drive] += size }
  mounted = DRIVES.filter_map do |(name, tb, *, connected, _, _)|
    serial = serials[name]
    m.update_drive_usage(serial, used_bytes: used[name], free_bytes: tb * TB - used[name],
                                 seen_at: connected ? iso(NOW - 3600) : '2026-09-15T20:00:00Z')
    next unless connected

    EasySync::Jbod::MountedDrive.new(drive: m.drive(serial), mount_point: "/Volumes/#{name}", capacity_bytes: tb * TB,
                                     used_bytes: used[name], free_bytes: tb * TB - used[name])
  end

  html = File.join(dir, 'dashboard.html')
  EasySync::Jbod::Dashboard.new(m, clock: FixedClock.new(NOW), backblaze_dir: fake_backblaze(dir))
                           .write(html, mounted: mounted, source_status: folders.to_h { |(path)| [path, :present] })
  html
end

abort "Google Chrome not found at #{CHROME}" unless File.executable?(CHROME)

Dir.mktmpdir('easy_sync_screenshot') do |dir|
  html = render(dir)
  FileUtils.mkdir_p(IMAGES)
  # Blink's preferredColorScheme: 0 is dark, 1 is light. The window stops
  # just below the drive tiles.
  { 'light' => 1, 'dark' => 0 }.each do |theme, scheme|
    png = File.join(IMAGES, "dashboard-#{theme}.png")
    system(CHROME, '--headless', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=2',
           '--window-size=1100,1010', "--blink-settings=preferredColorScheme=#{scheme}", "--screenshot=#{png}",
           "file://#{html}", out: File::NULL, err: File::NULL) or abort "Chrome failed for #{theme}"
    system('sips', '-Z', '1600', png, out: File::NULL) or abort "sips failed for #{png}"
    puts "wrote #{png}"
  end
end
