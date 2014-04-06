easy_sync
=========

### Why?
* Did you just get a shiny new 1TB 2.5 inch external hard drive and suddenly have the urge to back :poop: up?
* Did you just hear about [CryptoLocker](http://en.wikipedia.org/wiki/CryptoLocker) and thought crap how can i protect my friends and family?

**Note:** Once you get [CryptoLocker](http://en.wikipedia.org/wiki/CryptoLocker) it will encrypt the crap out
of any drive letter it can find including mapped network shares :cry:

Now if you use **Ruby** plus **Rsync** you can easily have many cold snapshots to restore from :thumbsup:


### Installation
    gem install easy_sync


### Requirements
* rsync 2.5.6 and up


### Usage
Just run **easy_sync** to generate a template mapping file, configure
your paths and next time you run **easy_sync** it will create the first
backup. After first backup it will create incremental backups.


### Todo
* ~~Given a source and destination a snapshot should be created.~~
* ~~It should use the latest backup for Rsync's --link-dest option and create a new snapshot with the files that changed.~~
* ~~Add logging~~
* If source or destination doesn't exists don't run rsync
* ~~excluded list~~
* ~~Support multiple source and destination configurations by using a yaml config file.~~
* ~~Convert to a gem and create a easy_sync bin file~~
