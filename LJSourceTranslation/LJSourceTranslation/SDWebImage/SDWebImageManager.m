/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageManager.h"
#import <objc/message.h>
#import "NSImage+WebCache.h"

@interface SDWebImageCombinedOperation : NSObject <SDWebImageOperation>
// ⚠️注意SDWebImageCombinedOperation遵循SDWebImageOperation，所以实现了cancel方法
@property (assign, nonatomic, getter = isCancelled) BOOL cancelled;
@property (copy, nonatomic, nullable) SDWebImageNoParamsBlock cancelBlock;
// 根据cacheType获取到image，这里虽然名字用的是cache，但是如果cache没有获取到图片
// 还是要把image下载下来的。此处只是把通过cache获取image和通过download获取image封装起来
@property (strong, nonatomic, nullable) NSOperation *cacheOperation;

@end

@interface SDWebImageManager ()

@property (strong, nonatomic, readwrite, nonnull) SDImageCache *imageCache;
@property (strong, nonatomic, readwrite, nonnull) SDWebImageDownloader *imageDownloader;
@property (strong, nonatomic, nonnull) NSMutableSet<NSURL *> *failedURLs;
@property (strong, nonatomic, nonnull) NSMutableArray<SDWebImageCombinedOperation *> *runningOperations;

@end

@implementation SDWebImageManager

+ (nonnull instancetype)sharedManager {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

// 使用SDImageCache和SDWebImageDownloader来初始化SDWebImageManager
- (nonnull instancetype)init {
    SDImageCache *cache = [SDImageCache sharedImageCache];
    SDWebImageDownloader *downloader = [SDWebImageDownloader sharedDownloader];
    return [self initWithCache:cache downloader:downloader];
}

// 初始化方法.
// 1.获得一个SDImageCache的单例.2.获取一个SDWebImageDownloader的单例.3.新建一个MutableSet来存储下载失败的url.
// 4.新建一个用来存储下载operation的可变数组.
// 为什么不用MutableArray储存下载失败的URL?
// 因为NSSet类有一个特性,就是Hash.实际上NSSet是一个哈希表,哈希表比数组优秀的地方是什么呢?就是查找速度快.查找同样一个元素,哈希表只需要通过key
// 即可取到,而数组至少需要遍历依次.因为SDWebImage里有关失败URL的业务需求是,一个失败的URL只需要储存一次.这样的话Set自然比Array更合适.
- (nonnull instancetype)initWithCache:(nonnull SDImageCache *)cache downloader:(nonnull SDWebImageDownloader *)downloader {
    if ((self = [super init])) {
        _imageCache = cache;
        _imageDownloader = downloader;
        _failedURLs = [NSMutableSet new];
        _runningOperations = [NSMutableArray new];
    }
    return self;
}

// 利用Image的URL生成一个缓存时需要的key.
// 这里有两种情况,第一种是如果检测到cacheKeyFilter不为空时,利用cacheKeyFilter来处理URL生成一个key.
// 如果为空,那么直接返回URL的string内容,当做key.
- (nullable NSString *)cacheKeyForURL:(nullable NSURL *)url {
    if (!url) {
        return @"";
    }
    // ⚠️如果设置了缓存key的过滤器，过滤一下url
    if (self.cacheKeyFilter) {
        return self.cacheKeyFilter(url);
    } else {
        // 否则直接使用url
        return url.absoluteString;
    }
}

// 检测一张图片是否已被缓存.
// 首先检测内存缓存是否存在这张图片,如果已有,直接返回yes.
// 如果内存缓存里没有这张图片,那么调用diskImageExistsWithKey这个方法去硬盘缓存里找
- (void)cachedImageExistsForURL:(nullable NSURL *)url
                     completion:(nullable SDWebImageCheckCacheCompletionBlock)completionBlock {
    NSString *key = [self cacheKeyForURL:url];
    
    BOOL isInMemoryCache = ([self.imageCache imageFromMemoryCacheForKey:key] != nil);
    
    if (isInMemoryCache) {
        // making sure we call the completion block on the main queue
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionBlock) {
                completionBlock(YES);
            }
        });
        return;
    }
    
    [self.imageCache diskImageExistsWithKey:key completion:^(BOOL isInDiskCache) {
        // the completion block of checkDiskCacheForImageWithKey:completion: is always called on the main queue, no need to further dispatch
        if (completionBlock) {
            completionBlock(isInDiskCache);
        }
    }];
}

// 首先生成一个用来cache 住Image的key(利用key的url生成)
// 然后检测内存缓存里是否已经有这张图片
// 如果已经被缓存,那么再主线程里回调block
// 如果没有检测到,那么调用diskImageExistsWithKey,这个方法会在异步线程里,将图片存到硬盘,当然在存图之前也会检测是否已在硬盘缓存图片
- (void)diskImageExistsForURL:(nullable NSURL *)url
                   completion:(nullable SDWebImageCheckCacheCompletionBlock)completionBlock {
    NSString *key = [self cacheKeyForURL:url];
    
    [self.imageCache diskImageExistsWithKey:key completion:^(BOOL isInDiskCache) {
        // the completion block of checkDiskCacheForImageWithKey:completion: is always called on the main queue, no need to further dispatch
        if (completionBlock) {
            completionBlock(isInDiskCache);
        }
    }];
}

// 通过url建立一个op对象用来下载图片.
- (id <SDWebImageOperation>)loadImageWithURL:(nullable NSURL *)url
                                     options:(SDWebImageOptions)options
                                    progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                                   completed:(nullable SDInternalCompletionBlock)completedBlock {
    // Invoking this method without a completedBlock is pointless
    // 如果没有设置completedBlock来调用这个方法是没有意义的
    NSAssert(completedBlock != nil, @"If you mean to prefetch the image, use -[SDWebImagePrefetcher prefetchURLs] instead");

    // Very common mistake is to send the URL using NSString object instead of NSURL. For some strange reason, Xcode won't
    // throw any warning for this type mismatch. Here we failsafe this error by allowing URLs to be passed as NSString.
    // 有时候xcode不会警告这个类型错误（将NSSTring当做NSURL），所以这里做一下容错
    if ([url isKindOfClass:NSString.class]) {
        url = [NSURL URLWithString:(NSString *)url];
    }

    // Prevents app crashing on argument type error like sending NSNull instead of NSURL
    // 阻止app由于类型错误的奔溃，像用NSNull代替NSURL
    if (![url isKindOfClass:NSURL.class]) {
        url = nil;
    }

    __block SDWebImageCombinedOperation *operation = [SDWebImageCombinedOperation new];
    __weak SDWebImageCombinedOperation *weakOperation = operation;

    // 创建一个互斥锁防止现在有别的线程修改failedURLs.
    // 判断这个url是否是fail过的.如果url failed过的那么isFailedUrl就是true
    BOOL isFailedUrl = NO;
    if (url) {
        @synchronized (self.failedURLs) {
            isFailedUrl = [self.failedURLs containsObject:url];
        }
    }
    
    // 1.如果url的长度为0时候执行
    // 2.当前url在失败的URL列表中，且options 不为 SDWebImageRetryFailed   时候执行
    if (url.absoluteString.length == 0 || (!(options & SDWebImageRetryFailed) && isFailedUrl)) {
        // 这里做的就是抛出错误,文件不存在
        [self callCompletionBlockForOperation:operation completion:completedBlock error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil] url:url];
        return operation;
    }

    // 创建一个互斥锁防止现在有别的线程修改runningOperations.
    @synchronized (self.runningOperations) {
        [self.runningOperations addObject:operation];
    }
    
    // 通过url来获取到对应的cacheKey
    NSString *key = [self cacheKeyForURL:url];
    
    // 这里设定了operation的缓存队列，通过上面获取到的cacheKey来查询缓存
    // queryCacheOperationForKey是通过key来获取缓存，无论是从内存，从磁盘中还是从网络
    operation.cacheOperation = [self.imageCache queryCacheOperationForKey:key done:^(UIImage *cachedImage, NSData *cachedData, SDImageCacheType cacheType) {
        // 如果对当前operation进行了取消操作，在SDWebImageManager的runningOperations移除operation
        if (operation.isCancelled) {
            [self safelyRemoveOperationFromRunning:operation];
            return;
        }
        // 1.cachedImage为nil，SDWebImageManager的代理对象没有实现imageManager:shouldDownloadImageForURL:(如果无缓存，这种就是默认情况)
        // 2.cachedImage为nil，SDWebImageManager的代理对象，YES--->代理对象返回（当图像没有在内存中找到的时候，控制是否下载图像）(无缓存，但是实现了代理方法且返回YES)
        // 3.options为SDWebImageRefreshCached，SDWebImageManager的代理对象没有实现imageManager:shouldDownloadImageForURL:
        // 4.options为SDWebImageRefreshCached，SDWebImageManager的代理对象，YES--->代理对象返回（当图像没有在内存中找到的时候，控制是否下载图像）
        if ((!cachedImage || options & SDWebImageRefreshCached) && (![self.delegate respondsToSelector:@selector(imageManager:shouldDownloadImageForURL:)] || [self.delegate imageManager:self shouldDownloadImageForURL:url])) {
            // ⚠️cachedImage不为nil，options为SDWebImageRefreshCached
            if (cachedImage && options & SDWebImageRefreshCached) {
                // If image was found in the cache but SDWebImageRefreshCached is provided, notify about the cached image
                // AND try to re-download it in order to let a chance to NSURLCache to refresh it from server.
                // 如果在缓存中找到图像，但提供了SDWebImageRefreshCached，请通知有关缓存的图像，并尝试重新下载它，以便让NSURLCache从服务器刷新它。
                [self callCompletionBlockForOperation:weakOperation completion:completedBlock image:cachedImage data:cachedData error:nil cacheType:cacheType finished:YES url:url];
            }

            // download if no image or requested to refresh anyway, and download allowed by delegate
            // 如果没有图像或请求刷新，下载，以及代理允许的下载
            // a |= b     ------>   a = a | b      按位或
            // unsigned char a=5,b=11; 5 ==0000 0101 (二进制)   10==0000 1011  a | b==   0000 1111
            // a & b   a=1   b=2    a== 0000 0001（二进制） b== 0000 0010(二进制)     a & b = 0000    按位与
            SDWebImageDownloaderOptions downloaderOptions = 0;
            if (options & SDWebImageLowPriority) downloaderOptions |= SDWebImageDownloaderLowPriority;
            if (options & SDWebImageProgressiveDownload) downloaderOptions |= SDWebImageDownloaderProgressiveDownload;
            // 如果上面的⚠️成立，那么会进入下面的判断 downloaderOptions = 0000 0000 | 0000 0100 == 0000 0100
            if (options & SDWebImageRefreshCached) downloaderOptions |= SDWebImageDownloaderUseNSURLCache;
            if (options & SDWebImageContinueInBackground) downloaderOptions |= SDWebImageDownloaderContinueInBackground;
            if (options & SDWebImageHandleCookies) downloaderOptions |= SDWebImageDownloaderHandleCookies;
            if (options & SDWebImageAllowInvalidSSLCertificates) downloaderOptions |= SDWebImageDownloaderAllowInvalidSSLCertificates;
            if (options & SDWebImageHighPriority) downloaderOptions |= SDWebImageDownloaderHighPriority;
            if (options & SDWebImageScaleDownLargeImages) downloaderOptions |= SDWebImageDownloaderScaleDownLargeImages;
            
            // ⚠️这里的判断条件和上面是一样的，看上面的⚠️标记(cachedImage不为nil，options为SDWebImageRefreshCached)
            if (cachedImage && options & SDWebImageRefreshCached) {
                // force progressive off if image already cached but forced refreshing
                // 相当于downloaderOptions =  downloaderOption & ~SDWebImageDownloaderProgressiveDownload);
                // downloaderOptions = 0000 0100 & 1111 1101 == 0000 0100
                downloaderOptions &= ~SDWebImageDownloaderProgressiveDownload;
                // ignore image read from NSURLCache if image if cached but force refreshing
                // 相当于 downloaderOptions = (downloaderOptions | SDWebImageDownloaderIgnoreCachedResponse);
                // downloaderOptions = 0000 0100 | 0000 1000 == 0000 1100
                downloaderOptions |= SDWebImageDownloaderIgnoreCachedResponse;
            }
            
            // 创建一个下载的TOKEN
            // 调用imageDownloader去下载image
            SDWebImageDownloadToken *subOperationToken = [self.imageDownloader downloadImageWithURL:url options:downloaderOptions progress:progressBlock completed:^(UIImage *downloadedImage, NSData *downloadedData, NSError *error, BOOL finished) {
                
                // strong可以参考这个文章
                // http://www.jianshu.com/p/bb63aabdb2db
                __strong __typeof(weakOperation) strongOperation = weakOperation;
                // operation（非subOperationToken）取消了,SDWebImageCombinedOperation
                // 什么都不做。因为如果你要在此处调用completedBlock的话，可能会存在和其他的completedBlock产生条件竞争，可能会修改同一个数据
                if (!strongOperation || strongOperation.isCancelled) {
                    // Do nothing if the operation was cancelled
                    // See #699 for more details
                    // if we would call the completedBlock, there could be a race condition between this block and another completedBlock for the same object, so if this one is called second, we will overwrite the new data
                    // 如果我们调用完成的block，在这个block和另一个完成的block之间可能存在竞争条件，因此如果这个被第二个调用，我们将覆盖新的数据
                } else if (error) {
                    // 判断operation是否取消了（检查是否取消要勤快点），没有取消，就调用completedBlock，处理error。
                    [self callCompletionBlockForOperation:strongOperation completion:completedBlock error:error url:url];
                    // 检查错误类型，确认不是客户端或者服务器端的网络问题，就认为这个url本身问题了。并把这个url放到failedURLs中
                    if (   error.code != NSURLErrorNotConnectedToInternet
                        && error.code != NSURLErrorCancelled
                        && error.code != NSURLErrorTimedOut
                        && error.code != NSURLErrorInternationalRoamingOff
                        && error.code != NSURLErrorDataNotAllowed
                        && error.code != NSURLErrorCannotFindHost
                        && error.code != NSURLErrorCannotConnectToHost
                        && error.code != NSURLErrorNetworkConnectionLost) {
                        @synchronized (self.failedURLs) {
                            [self.failedURLs addObject:url];
                        }
                    }
                }
                else {
                    // 如果使用了SDWebImageRetryFailed选项，那么即使该url是failedURLs，也要从failedURLs移除，并继续执行download：
                    if ((options & SDWebImageRetryFailed)) {
                        @synchronized (self.failedURLs) {
                            [self.failedURLs removeObject:url];
                        }
                    }
                    // 如果不设定SDWebImageCacheMemoryOnly，那么cacheOnDisk为YES
                    BOOL cacheOnDisk = !(options & SDWebImageCacheMemoryOnly);

                    if (options & SDWebImageRefreshCached && cachedImage && !downloadedImage) {
                        // Image refresh hit the NSURLCache cache, do not call the completion block
                        // 图像刷新命中NSURLCache缓存，不调用回调
                        // image是从SDImageCache中获取的，downloadImage是从网络端获取的
                        // 所以虽然options包含SDWebImageRefreshCached，需要刷新imageCached，
                        // 并使用downloadImage，不过可惜downloadImage没有从网络端获取到图片。
                    } else if (downloadedImage && (!downloadedImage.images || (options & SDWebImageTransformAnimatedImage)) && [self.delegate respondsToSelector:@selector(imageManager:transformDownloadedImage:withURL:)]) {
                        // 图片下载成功，获取到了downloadedImage。
                        // 这时候如果想transform已经下载的图片，就得先判断这个图片是不是animated image（动图），
                        // 这里可以通过downloadedImage.images是不是为空判断。
                        // 默认情况下，动图是不允许transform的，不过如果options选项中有SDWebImageTransformAnimatedImage，也是允许transform的。
                        // 当然，静态图片不受此干扰。另外，要transform图片，还需要实现
                        // transformDownloadedImage这个方法，这个方法是在SDWebImageManagerDelegate代理定义的
                        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                            // 如果获得了新的transformedImage,不管transform后是否改变了图片.都要存储到缓存中。区别在于如果transform后的图片和之前不一样，就需要重新生成imageData，而不能在使用之前最初的那个imageData了。
                            UIImage *transformedImage = [self.delegate imageManager:self transformDownloadedImage:downloadedImage withURL:url];

                            if (transformedImage && finished) {
                                BOOL imageWasTransformed = ![transformedImage isEqual:downloadedImage];
                                // pass nil if the image was transformed, so we can recalculate the data from the image
                                // 如果图像被转换，则给imageData传入nil，因此我们可以从图像重新计算数据
                                [self.imageCache storeImage:transformedImage imageData:(imageWasTransformed ? nil : downloadedData) forKey:key toDisk:cacheOnDisk completion:nil];
                            }
                            
                            [self callCompletionBlockForOperation:strongOperation completion:completedBlock image:transformedImage data:downloadedData error:nil cacheType:SDImageCacheTypeNone finished:finished url:url];
                        });
                    } else {
                        // 下载好了图片且完成了
                        if (downloadedImage && finished) {
                            [self.imageCache storeImage:downloadedImage imageData:downloadedData forKey:key toDisk:cacheOnDisk completion:nil];
                        }
                        [self callCompletionBlockForOperation:strongOperation completion:completedBlock image:downloadedImage data:downloadedData error:nil cacheType:SDImageCacheTypeNone finished:finished url:url];
                    }
                }
                // 下载结束后移除对应operation
                if (finished) {
                    [self safelyRemoveOperationFromRunning:strongOperation];
                }
            }];
            // 对应的operation的取消操作
            operation.cancelBlock = ^{
                [self.imageDownloader cancel:subOperationToken];
                // LJMARK:外部的weak现在变成strong
                __strong __typeof(weakOperation) strongOperation = weakOperation;
                [self safelyRemoveOperationFromRunning:strongOperation];
            };
        } else if (cachedImage) {
            // 如果有缓存，返回缓存
            __strong __typeof(weakOperation) strongOperation = weakOperation;
            // 直接执行completedBlock，其中error置为nil即可。
            [self callCompletionBlockForOperation:strongOperation completion:completedBlock image:cachedImage data:cachedData error:nil cacheType:cacheType finished:YES url:url];
            [self safelyRemoveOperationFromRunning:operation];
        } else {
            // Image not in cache and download disallowed by delegate
            // 不在缓存中，不被代理允许下载
            __strong __typeof(weakOperation) strongOperation = weakOperation;
            // completedBlock中image和error均传入nil。
            [self callCompletionBlockForOperation:strongOperation completion:completedBlock image:nil data:nil error:nil cacheType:SDImageCacheTypeNone finished:YES url:url];
            [self safelyRemoveOperationFromRunning:operation];
        }
    }];

    return operation;
}

//
- (void)saveImageToCache:(nullable UIImage *)image forURL:(nullable NSURL *)url {
    if (image && url) {
        NSString *key = [self cacheKeyForURL:url];
        [self.imageCache storeImage:image forKey:key toDisk:YES completion:nil];
    }
}

// cancel掉所有正在执行的operation
- (void)cancelAll {
    @synchronized (self.runningOperations) {
        NSArray<SDWebImageCombinedOperation *> *copiedOperations = [self.runningOperations copy];
        [copiedOperations makeObjectsPerformSelector:@selector(cancel)];
        [self.runningOperations removeObjectsInArray:copiedOperations];
    }
}

// 判断是否有正在运行的operation
- (BOOL)isRunning {
    BOOL isRunning = NO;
    @synchronized (self.runningOperations) {
        isRunning = (self.runningOperations.count > 0);
    }
    return isRunning;
}

// 执行完后，说明图片获取成功，可以把当前这个operation溢移除了。
- (void)safelyRemoveOperationFromRunning:(nullable SDWebImageCombinedOperation*)operation {
    @synchronized (self.runningOperations) {
        if (operation) {
            [self.runningOperations removeObject:operation];
        }
    }
}

// 这里就是直接调用完成的回调
- (void)callCompletionBlockForOperation:(nullable SDWebImageCombinedOperation*)operation
                             completion:(nullable SDInternalCompletionBlock)completionBlock
                                  error:(nullable NSError *)error
                                    url:(nullable NSURL *)url {
    [self callCompletionBlockForOperation:operation completion:completionBlock image:nil data:nil error:error cacheType:SDImageCacheTypeNone finished:YES url:url];
}

// 这里就是直接调用完成的回调
- (void)callCompletionBlockForOperation:(nullable SDWebImageCombinedOperation*)operation
                             completion:(nullable SDInternalCompletionBlock)completionBlock
                                  image:(nullable UIImage *)image
                                   data:(nullable NSData *)data
                                  error:(nullable NSError *)error
                              cacheType:(SDImageCacheType)cacheType
                               finished:(BOOL)finished
                                    url:(nullable NSURL *)url {
    dispatch_main_async_safe(^{
        if (operation && !operation.isCancelled && completionBlock) {
            completionBlock(image, data, error, cacheType, finished, url);
        }
    });
}

@end


@implementation SDWebImageCombinedOperation

- (void)setCancelBlock:(nullable SDWebImageNoParamsBlock)cancelBlock {
    // check if the operation is already cancelled, then we just call the cancelBlock
    // 如果该operation已经取消了，我们只是调用回调block
    if (self.isCancelled) {
        if (cancelBlock) {
            cancelBlock();
        }
        _cancelBlock = nil; // don't forget to nil the cancelBlock, otherwise we will get crashes
        // 不要忘了设置cacelBlock为nil，否则可能会奔溃
    } else {
        _cancelBlock = [cancelBlock copy];
    }
}

// SDWebImageCombinedOperation遵循SDWebImageOperation协议
- (void)cancel {
    self.cancelled = YES;
    if (self.cacheOperation) {
        [self.cacheOperation cancel];
        self.cacheOperation = nil;
    }
    if (self.cancelBlock) {
        self.cancelBlock();
        
        // TODO: this is a temporary fix to #809.
        // Until we can figure the exact cause of the crash, going with the ivar instead of the setter
//        self.cancelBlock = nil;
        _cancelBlock = nil;
    }
}

@end
