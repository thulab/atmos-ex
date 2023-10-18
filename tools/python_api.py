from datetime import datetime
import numpy as np

from iotdb.Session import Session
from iotdb.utils.IoTDBConstants import TSDataType, TSEncoding, Compressor
from iotdb.utils.NumpyTablet import NumpyTablet

# creating session connection.
ip = "127.0.0.1"
port_ = "6667"
username_ = "root"
password_ = "root"
session = Session(ip, port_, username_, password_, fetch_size=1024, zone_id="UTC+8", enable_redirection=False)

session.open(False)

device = "root.sg.d"
measurements_ = []
ts_path_lst_ = []
values_ = []
for i in range(440):
    measurement = "s" + str(i)
    measurements_.append(measurement)
    ts_path_lst_.append(device + "." + measurement)
    values_.append(1.1 * i)

data_type_lst_ = [TSDataType.FLOAT for _ in range(440)]
encoding_lst_ = [TSEncoding.GORILLA for _ in range(440)]
compressor_lst_ = [Compressor.LZ4 for _ in range(440)]
# 创建单设备 440 Float 类型序列
session.create_multi_time_series(
    ts_path_lst_, data_type_lst_, encoding_lst_, compressor_lst_
)

# insertRecord 插入10000行数据
startTime = int(datetime.now().timestamp() * 1000)
for i in range(1000000):
    session.insert_record(device, 1692761800000 + i, measurements_, data_type_lst_, values_)
print("InsertRecord 1000000 rows cost: " + str(int(datetime.now().timestamp() * 1000) - startTime) + " ms")

# insertRecords 插入10000行数据耗时
measurements_list_ = []
values_list_ = []
data_type_list_ = []
device_ids_ = []

for i in range(100):
    device_ids_.append(device)
    data_type_list_.append(data_type_lst_)
    measurements_list_.append(measurements_)
    values_list_.append(values_)
# 插入100次 每次100行
startTime = int(datetime.now().timestamp() * 1000)
for i in range(10000):
    time_list = []
    for j in range(100):
        time_list.append(1692761900000 + i * 100 + j)
    session.insert_records(
        device_ids_, time_list, measurements_list_, data_type_list_, values_list_
    )
print("InsertRecords 1000000 rows cost: " + str(int(datetime.now().timestamp() * 1000)- startTime) + " ms")

# insertTablet 插入10000行数据
np_values_ = []
for i in range(440):
    np_values_.append(np.array([1.1 * i for _ in range(100)], TSDataType.FLOAT.np_dtype()))

# 插入100次 每次100行
startTime = int(datetime.now().timestamp() * 1000)
for i in range(100000):
    np_timestamps_ = np.array([1692762000000 + i * 100 + j for j in range(100)], TSDataType.INT64.np_dtype())
    np_tablet_ = NumpyTablet(
        device, measurements_, data_type_lst_, np_values_, np_timestamps_
    )
    session.insert_tablet(np_tablet_)
print("InsertTablet by numpy 10000000 rows cost: " + str(int(datetime.now().timestamp() * 1000) - startTime) + " ms")
print("All executions done!!")
