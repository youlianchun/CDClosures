//
//  CDClosures.swift
//  CDClosures
//
//  Created by YLCHUN on 2018/7/18.
//  Copyright © 2018年 ylchun. All rights reserved.
//
//  CoreData Closures

import Foundation
import CoreData

private func cdcMainThread(code:@escaping ()->Void) {
    if Thread.current.isMainThread { code() }
    else { DispatchQueue.main.async { code() } }
}

private protocol CDCCatchEx {
    func catchBegin()
    func catchEnd()
}

@discardableResult
private func cdcCatchError(msg:String? = nil, lock:NSLock? = nil, ex:CDCCatchEx? = nil, try:() throws -> Void) -> NSError? {
    var error:NSError?
    lock?.lock()
    ex?.catchBegin()
    do { try `try`() }
    catch let err as NSError {
        if let msg = msg {
            error = NSError(domain: msg + ": " + err.domain, code: err.code, userInfo: err.userInfo)
        }else {
            error = err
        }
    }
    ex?.catchEnd()
    lock?.unlock()
    return error
}

private func cdcCatchThrows(msg:String? = nil, lock:NSLock? = nil, ex:CDCCatchEx? = nil, try:() throws -> Void) throws {
    if let err = cdcCatchError(msg: msg, lock: lock, ex: ex, try: `try`) { throw err }
}

fileprivate extension NSError {
    class func unregister() -> NSError {
        return NSError(domain: "unregister CDClosures, please call \"registerCDClosures(fileName)\" at first.", code: 400, userInfo: nil)
    }
    class func unfindEntity(entity:String)  -> NSError {
        return NSError(domain: "unfind entity: \"\(entity)\".", code: 401, userInfo: nil)
    }
    class func unfindMomd(momd:String) -> NSError {
        return NSError(domain: "unfind momd: \"\(momd)\".", code: 402, userInfo: nil)
    }
    class func canNotInitManaged(momd:String) -> NSError {
        return NSError(domain: "can't init NSManagedObjectModel whith momd: \"\(momd)\".", code: 403, userInfo: nil)
    }
    class func canNotSaveSqlite(momd:String) -> NSError {
        return NSError(domain: "can't save sqlite to document directory whith momd: \"\(momd)\".", code: 404, userInfo: nil)
    }
}

fileprivate extension NSPersistentStoreCoordinator {
    convenience init(name:String) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "momd")
            else { throw NSError.unfindMomd(momd: name) }
        guard let model = NSManagedObjectModel(contentsOf: url)
            else { throw NSError.canNotInitManaged(momd: name) }
        
        guard let sqlpath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            else { throw NSError.canNotSaveSqlite(momd: name) }
        var sqliteURL = URL(fileURLWithPath: sqlpath)
        sqliteURL.appendPathComponent("\(name).sqlite")
        
        self.init(managedObjectModel: model)
        let options = [NSMigratePersistentStoresAutomaticallyOption:true,
                       NSInferMappingModelAutomaticallyOption:true]
        
        try self.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: sqliteURL, options: options)
    }
}

fileprivate extension NSManagedObjectContext
{
    class func create(name:String) throws -> NSManagedObjectContext {
        if #available(iOS 10.0, *) {
            return try managedObjectContext_10(name)
        } else {
            return try managedObjectContext_9(name)
        }
    }
    
    private static func managedObjectContext_9(_ name:String) throws -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = try NSPersistentStoreCoordinator(name: name)
        return context
    }
    
    @available(iOS 10.0, *)
    private static func managedObjectContext_10(_ name:String) throws -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: name)
        var err:NSError?
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            err = error as NSError?
        })
        if let err = err { throw err }

        let context:NSManagedObjectContext? = container.newBackgroundContext()
        guard let ctx = context
            else { throw NSError.unfindMomd(momd: name) }
        return ctx
    }
    
    func entityMap () -> [String:String] {
        var map:[String:String] = [:]
        if let store = self.persistentStoreCoordinator {
            for entitie in store.managedObjectModel.entities {
                guard let className = entitie.managedObjectClassName else { continue }
                map[className] = entitie.name ?? className
            }
        }
        return map
    }
}

public class CDCMap<Key, Value> where Key : Hashable {
    fileprivate lazy var dict = [Key:Value]()
    public subscript(key: Key) -> Value? {
        get { return dict[key] }
        set { dict[key] = newValue }
    }
}

private class CDCSaver: NSObject, CDCCatchEx {
    private var cb:((Bool)->Void)!
    private var time:TimeInterval = 0
    
    private override init() { super.init() }
    convenience init(time:TimeInterval = 0.2, cb:@escaping(Bool)->Void) {
        self.init()
        self.time = time
        self.cb = cb
    }
    
    func cancelPreviousPerform() {
        cdcMainThread {
            NSObject.cancelPreviousPerformRequests(withTarget: self)
        }
    }
    
    func perform(delay:Bool) {
        cancelPreviousPerform()
        if !delay {
            cb(false)
        }else {
            performDelay()
        }
    }
    
    private func performDelay() {
        cdcMainThread {
            self.perform(#selector(self.onTime), with: nil, afterDelay: self.time, inModes: [.commonModes,.defaultRunLoopMode])
        }
    }
    
    @objc private func onTime() {
        DispatchQueue.global().async {
            self.cb(true)
        }
    }
    
    func catchBegin() { cancelPreviousPerform() }
    func catchEnd() { performDelay() }
}

public func registerCDClosures(_ name:String) throws {
    try CDClosures.default(name: name)
}


public enum CDCSortOp {
    case desc
    case asc
}
public typealias CDCSort = (key:String, value:CDCSortOp)
public typealias CDCRange = (loc:UInt, len:UInt)

fileprivate class CDClosures
{
    private static let initlock = NSLock()
    private static var modelMap:[String:String] = [:]//className:fileName
    private static var map:[String:CDClosures] = [:]//fileName:CDClosures
    
    @discardableResult
    fileprivate class func `default`<T:NSManagedObject>(managedClass :T.Type) throws -> CDClosures {
        guard let name = CDClosures.modelMap["\(T.self)"] else {
            throw NSError.unregister()
        }
        return try self.default(name: name)
    }
    
    @discardableResult
    fileprivate class func `default`(name:String) throws -> CDClosures {
        initlock.lock()
        var err:NSError?
        var cdc:CDClosures? = map[name]
        if cdc == nil {
           err = cdcCatchError {
                let context = try NSManagedObjectContext.create(name:name)
                cdc = CDClosures(name, context)
                map[name] = cdc
            }
        }
        initlock.unlock()
        if let err = err { throw err }
        return cdc!
    }
    
    private let name:String
    private let lock = NSLock()
    private let context:NSManagedObjectContext
    private let entityMap:[String:String]
    private lazy var saver = CDCSaver() {[weak self] (delay) in
        guard let `self` = self else { return }
        let lock = delay ? `self`.lock : nil
        if let err = (cdcCatchError(msg: "save error", lock: lock) {
            try `self`.context.save()
        }) { debugPrint(err) }
    }
    
    private init(_ name:String, _ context:NSManagedObjectContext) {
        self.name = name
        self.context = context
        self.entityMap = context.entityMap()
        for (k, _) in self.entityMap {
            CDClosures.modelMap.updateValue(name, forKey: k)
        }
        setNotification()
    }
    
    private func setNotification() {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(needSave), name: .UIApplicationDidEnterBackground, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(needSave), name: .UIApplicationWillTerminate, object: nil)
    }
    
    @objc private func needSave() {
        cdcCatchError(lock: lock) {
            self.saver.perform(delay: false)
        }
    }
    
    private func entityName<T:NSManagedObject>(_ :T.Type) -> String {
        let className = "\(T.self)"
        guard let name = entityMap[className] else { return className }
        return name
    }

    private func fetchRequest<T:NSManagedObject>(_ :T.Type, where:String? = nil, range:CDCRange? = nil, groupBy:[String]? = nil, sorts:[CDCSort]? = nil) -> NSFetchRequest<T> {
        var request:NSFetchRequest<T>
        if #available(iOS 10.0, *) {
            request = T.fetchRequest() as! NSFetchRequest<T>
        } else {
            request = NSFetchRequest<T>(entityName: entityName(T.self))
        }
        if let `where` = `where`, `where`.count > 0 {
            let predicate = NSPredicate(format: `where`, argumentArray: nil)
            request.predicate = predicate
        }
        if let range = range, range.len > 0 {
            request.fetchOffset = Int(range.loc)
            request.fetchLimit = Int(range.len)
        }
        if let groupBy = groupBy, groupBy.count > 0  {
            request.propertiesToGroupBy = groupBy
        }
        if let sorts = sorts, sorts.count > 0 {
            request.sortDescriptors = sorts.map { NSSortDescriptor(key: $0.key, ascending: $0.value == .asc) }
        }
        return request
    }
    
    private func select<T:NSManagedObject>(_:T.Type, where:String? = nil, range:CDCRange? = nil, groupBy:[String]? = nil, sorts:[CDCSort]? = nil) throws -> [T] {
        let request = fetchRequest(T.self, where: `where`, range: range, groupBy: groupBy, sorts: sorts)
        return try context.fetch(request)
    }
    
    
    fileprivate func select<T:NSManagedObject>(_:T.Type, where:String? = nil, range:CDCRange? = nil, groupBy:[String]? = nil, sorts:[CDCSort]? = nil, cb:([T])->Void)throws {
        try cdcCatchThrows(msg: "select error", lock: lock) {
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.parent = self.context
            let request = fetchRequest(T.self, where: `where`, range: range, groupBy: groupBy, sorts: sorts)
            let ts = try context.fetch(request)
            cb(ts)
        }
    }
    
    fileprivate func update<T:NSManagedObject>(_:T.Type, where:String? = nil, cb:(T)->Void) throws -> Int {
        var count = 0
        try cdcCatchThrows(msg: "update error", lock: lock, ex: saver) {
            let ts = try select(T.self, where: `where`)
            for t in ts {
                cb(t)
            }
            count = ts.count
        }
        return count
    }
    
    fileprivate func insert<T:NSManagedObject>(_:T.Type, count:Int, cb:(Int, T)->Void) throws {
        try cdcCatchThrows(msg: "insert error", lock: lock, ex: saver) {
            let emptyName = entityName(T.self)
            guard let endesc = NSEntityDescription.entity(forEntityName: emptyName, in: context)
                else { throw NSError.unfindEntity(entity: emptyName) }
            for i in 0..<count {
                let t = T(entity: endesc, insertInto: context)
                cb(i,t)
                context.insert(t)
            }
        }
    }
    
    fileprivate func insert<T:NSManagedObject>(_:T.Type, cb:(T)->Void)throws {
        try insert(T.self, count: 1) { (idx, t) in
            cb(t)
        }
    }

    fileprivate func delete<T:NSManagedObject>(_:T.Type, where:String? = nil) throws -> Int {
        var count = 0
        try cdcCatchThrows(msg: "delete error", lock: lock, ex: saver) {
            let ts = try select(T.self, where: `where`)
            for t in ts {
                context.delete(t)
            }
            count = ts.count
        }
        return count
    }
    

    fileprivate func frc<T:NSManagedObject>(_:T.Type, delegate:NSFetchedResultsControllerDelegate, sectionNameKeyPath:String? = nil, where:String? = nil, range:CDCRange? = nil, groupBy:[String]? = nil, sorts:[CDCSort]? = nil) -> NSFetchedResultsController<T> {
        let request = fetchRequest(T.self, where: `where`, range: range, sorts: sorts)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.parent = self.context
        let fetchResultsController = NSFetchedResultsController(fetchRequest: request, managedObjectContext: context, sectionNameKeyPath: sectionNameKeyPath, cacheName:nil)
        fetchResultsController.delegate = delegate
        return fetchResultsController
    }
    
    @available(iOS 9.0, *)
    fileprivate func batchDelete<T:NSManagedObject>(_:T.Type, where:String? = nil) throws -> Int {
        var count = 0
        try cdcCatchThrows(msg: "batchUpdate error", lock: lock) {
            saver.perform(delay: false)
            let request = fetchRequest(T.self, where: `where`)
            let batchDelete = NSBatchDeleteRequest(fetchRequest: request as! NSFetchRequest<NSFetchRequestResult>)
            batchDelete.affectedStores = context.persistentStoreCoordinator!.persistentStores
            batchDelete.resultType = .resultTypeCount
            let result = try context.execute(batchDelete) as? NSBatchDeleteResult
            count = (result?.result as? NSNumber)?.intValue ?? 0
        }
        return count
    }
    
    fileprivate func batchUpdate<T:NSManagedObject>(_:T.Type, where:String? = nil, cb:(CDCMap<String, Any>)->Void) throws -> Int {
        var count = 0
        try cdcCatchThrows(msg: "batchDelete error", lock: lock) {
            saver.perform(delay: false)
            let batchUpdate = NSBatchUpdateRequest(entityName: entityName(T.self))
            if let `where` = `where` {
                batchUpdate.predicate = NSPredicate(format: `where`)
            }
            let update = CDCMap<String, Any>()
            cb(update)
            batchUpdate.propertiesToUpdate = update.dict
            batchUpdate.affectedStores = context.persistentStoreCoordinator!.persistentStores
            batchUpdate.resultType = .updatedObjectsCountResultType
            let result = try context.execute(batchUpdate) as? NSBatchUpdateResult
            count = (result?.result as? NSNumber)?.intValue ?? 0
        }
        return count
    }
}


public protocol CDClosuresProtocol where Self : NSManagedObject {}
extension NSManagedObject:CDClosuresProtocol {}

public extension CDClosuresProtocol
{
    private static func cdClosures() throws -> CDClosures {
        return try CDClosures.default(managedClass: self)
    }
    
    static func select(where:String? = nil, range:CDCRange? = nil, groupBy:[String]? = nil, sorts:[CDCSort]? = nil, cb:([Self])->Void)throws {
        try cdClosures().select(self, where: `where`, range: range, groupBy: groupBy, sorts: sorts, cb: cb)
    }
    
    @discardableResult
    static func update(where:String? = nil, cb:(Self)->Void) throws -> Int {
        return try cdClosures().update(self, where: `where`, cb: cb)
    }
    
    static func insert(count: Int, cb: (Int, Self) -> Void) throws {
        try cdClosures().insert(self, count: count, cb: cb)
    }
    
    static func insert(cb: (Self) -> Void) throws {
        try cdClosures().insert(self, cb: cb)
    }
    
    @discardableResult
    static func delete(where: String? = nil) throws -> Int {
        return try cdClosures().delete(self, where: `where`)
    }
}

/// 批处理操作，执行前会先将content进行持久化，批处理自身存在一定延迟
public extension CDClosuresProtocol {
    
    @discardableResult
    @available(iOS 9.0, *)
    static func batchDelete(where: String? = nil) throws -> Int {
        return try cdClosures().batchDelete(self, where: `where`)
    }
    
    @discardableResult
    static func batchUpdate(where:String? = nil, cb:(CDCMap<String, Any>)->Void) throws -> Int {
        return  try cdClosures().batchUpdate(self, where: `where`, cb: cb)
    }
    
    static func frc(delegate:NSFetchedResultsControllerDelegate, sectionNameKeyPath:String? = nil, where:String? = nil, range:CDCRange? = nil, groupBy:[String]? = nil, sorts:[CDCSort]? = nil) throws -> NSFetchedResultsController<Self> {
        return try cdClosures().frc(self, delegate: delegate, sectionNameKeyPath: sectionNameKeyPath, where: `where`, range: range, groupBy: groupBy, sorts: sorts)
    }
}

