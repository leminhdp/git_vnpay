#!/usr/bin/env python2.7
import requests
import sys
import argparse

def info():
    print ("A Nagios plugin for checking springboot service using API")


def check_springboot_service():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port")
    parser.add_argument("--host")
    parser.add_argument("-m", "--metric", help="Get metrics info",action="store_true")
    parser.add_argument("--warning", nargs='?', const=1, type=int, default=80)
    parser.add_argument("--critical", nargs='?', const=1, type=int, default=90)
    args = parser.parse_args()
    msg = ""
    status = ""
    heap_used = 0
    mem_used = 0

    try:
        resp = requests.get('http://{0}:{1}/health'.format(args.host, args.port), timeout=2.0).json()
    except:
        print ("FAIL!")
        sys.exit(2)

    status = resp['status']

    if args.metric:
        try:
            resp = requests.get('http://{0}:{1}/metrics'.format(args.host, args.port), timeout=2.0).json()
        except:
            print ("FAIL!")
            sys.exit(2)
        
        heap_used = (float(resp['heap.used'])/resp['heap.committed'])*100.0
        mem_used = (float((resp['mem']-resp['mem.free']))/resp['mem'])*100.0
        msg = "mem_free="+str(resp['mem.free'])+"Kb "+"mem_used={0:.2f}".format(mem_used)+"% processors="+str(resp['processors'])+" uptime="+str(resp['uptime'])+"ms load_avg="+str(resp['systemload.average'])+" threads="+str(resp['threads'])+" heap_used={0:.2f}".format(heap_used)+"%|mem_free="+str(resp['mem.free'])+"Kb "+"mem_used={0:.2f}".format(mem_used)+"% processors="+str(resp['processors'])+" uptime="+str(resp['uptime'])+"ms load_avg="+str(resp['systemload.average'])+" threads="+str(resp['threads'])+" heap_used={0:.2f}".format(heap_used)+"%"
    elif status == 'UP':
        msg = "Health is "+status
        print msg
        sys.exit(0)
    else:
        msg = "Health is "+status
        print msg
        sys.exit(2)

    if mem_used >= int(args.critical):
        print "Critical Mem used {0:.2f}".format(mem_used)+"%, " + msg
        sys.exit(2)
    if heap_used >= int(args.critical):
        print "Critical Heap used {0:.2f}".format(heap_used)+"%, " + msg
        sys.exit(2)
    if mem_used >= int(args.warning):
        print "Warning Mem used {0:.2f}".format(mem_used)+"%, " + msg
        sys.exit(1)
    if heap_used >= int(args.warning):
        print "Warning Heap used {0:.2f}".format(heap_used)+"%, " + msg
        sys.exit(1)
    print msg
    sys.exit(0)


check_springboot_service()
