easy_sync
=========

### Why?
* Did you just get a shiny new 1TB 2.5 inch external hard drive and suddenly have the urge to back :poop: up?
* Did you just hear about [CryptoLocker](http://en.wikipedia.org/wiki/CryptoLocker) and thought crap how can i protect my friends and family?

**Note:** Once you get [CryptoLocker](http://en.wikipedia.org/wiki/CryptoLocker) it will encrypt the crap out
of any drive letter it can find including mapped network shares :cry:

Now if you use **Ruby** plus **Rsync** you can easily have many months worth of cold snapshots to restore from :thumbsup:


### Installation
    coming soon
    
    
### Usage
    coming soon
    
    
### Todo
* on first run app should prompt for source path and destination path and create a yaml file
* given a source and destination a initial snapshot should be created
* it should use the latest backup for Rsync's --link-dest option and create a new snapshot with the files that changed
* support multiple source and destination configurations
* add ability to manage and modify configured backup paths
