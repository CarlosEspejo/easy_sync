# frozen_string_literal: true

require 'fiddle'

module EasySync
  module Jbod
    # Drops one file's pages from the macOS unified buffer cache, so the read
    # that follows comes off the drive. F_NOCACHE alone is not enough: it
    # stops a read from *adding* pages to the cache, but pages already there
    # (a file sync just wrote, or anything read recently) are still served
    # from RAM. Measured on jbod-test-1 (USB): a just-synced 100 MB file read
    # at 12,037 MB/s with F_NOCACHE, and at 156 MB/s after this. msync with
    # MS_INVALIDATE is the BSD/macOS stand-in for Linux's
    # posix_fadvise(DONTNEED) (vmtouch uses it the same way); MS_SYNC first
    # flushes any pending writes, so nothing unwritten is ever discarded.
    # Best effort: any failure just leaves the cache as it was.
    module PageCache
      PROT_READ = 0x01
      MAP_SHARED = 0x01
      MS_SYNC = 0x10
      MS_INVALIDATE = 0x02

      module_function

      def evict(io)
        len = io.size
        return false if len.zero?

        addr = functions[:mmap].call(nil, len, PROT_READ, MAP_SHARED, io.fileno, 0)
        return false if [-1, (2**64) - 1].include?(addr.to_i)

        begin
          functions[:msync].call(addr, len, MS_SYNC | MS_INVALIDATE).zero?
        ensure
          functions[:munmap].call(addr, len)
        end
      rescue StandardError, Fiddle::DLError
        false
      end

      def functions
        @functions ||= begin
          libc = Fiddle.dlopen(nil)
          {
            mmap: Fiddle::Function.new(libc['mmap'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_INT,
                                                      Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_LONG_LONG],
                                       Fiddle::TYPE_VOIDP),
            msync: Fiddle::Function.new(libc['msync'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T, Fiddle::TYPE_INT],
                                        Fiddle::TYPE_INT),
            munmap: Fiddle::Function.new(libc['munmap'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T], Fiddle::TYPE_INT)
          }
        end
      end
    end
  end
end
