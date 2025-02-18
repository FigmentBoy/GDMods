#import <Cocoa/Cocoa.h>
#import <Python.h>

int main(int argc, const char * argv[]) {

    @autoreleasepool {
        
        NSBundle *mainBundle = [NSBundle mainBundle];
        NSString *resourcePath = [mainBundle resourcePath];
        NSArray *pythonPathArray = [NSArray arrayWithObjects: resourcePath, [resourcePath stringByAppendingPathComponent:@"PyObjC"], nil];
        
        setenv("PYTHONPATH", [[pythonPathArray componentsJoinedByString:@":"] UTF8String], 1);
        
        NSArray *possibleMainExtensions = [NSArray arrayWithObjects: @"py", @"pyc", @"pyo", @"zip", nil];
        NSString *mainFilePath = nil;
        
        for (NSString *possibleMainExtension in possibleMainExtensions) {
            mainFilePath = [mainBundle pathForResource: @"main" ofType: possibleMainExtension];
            if ( mainFilePath != nil ) break;
        }
        
        if ( !mainFilePath ) {
            [NSException raise: NSInternalInconsistencyException format: @"%s:%d main() Failed to find the Main.{py,pyc,pyo} file in the application wrapper's Resources directory.", __FILE__, __LINE__];
        }
        
        Py_SetProgramName("/usr/bin/python");
        Py_Initialize();
        PySys_SetArgv(argc, (char **)argv);
        
        const char *mainFilePathPtr = [mainFilePath UTF8String];
        FILE *mainFile = fopen(mainFilePathPtr, "r");
        int result = PyRun_SimpleFile(mainFile, (char *)[[mainFilePath lastPathComponent] UTF8String]);
        
        if ( result != 0 ) {
            [NSException raise: NSInternalInconsistencyException
                        format: @"%s:%d main() PyRun_SimpleFile failed with file '%@'.  See console for errors.", __FILE__, __LINE__, mainFilePath];
        }
        return result;
    }
            
}
